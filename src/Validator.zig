const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const BinaryCursor = @import("BinaryCursor.zig");
const MaterializedDefaults = @import("MaterializedDefaults.zig");
const StringFormats = @import("StringFormats.zig");

pub const EffectiveAxes = struct {
    name_index: bool = true,
    ref_lookup: bool = true,
    exclusive_group: bool = true,
    variant: bool = true,
};

pub const Options = struct {
    overlay: ?*const MaterializedDefaults.MaterializedDefaults = null,
    overlays: ?[]const ?*const MaterializedDefaults.MaterializedDefaults = null,
    share_scope: bool = false,
    axes: EffectiveAxes = .{},

    fn anyAxisActive(self: Options) bool {
        if (self.overlay == null) return false;
        return self.axes.name_index or self.axes.ref_lookup or
            self.axes.exclusive_group or self.axes.variant;
    }
};

fn effectiveOverlay(options: Options, tree_idx: usize) ?*const MaterializedDefaults.MaterializedDefaults {
    if (options.overlays) |ovs| {
        std.debug.assert(tree_idx < ovs.len);
        return ovs[tree_idx];
    }
    return options.overlay;
}

fn perTreeOptions(options: Options, tree_idx: usize) Options {
    return .{
        .overlay = effectiveOverlay(options, tree_idx),
        .overlays = null,
        .axes = options.axes,
    };
}

pub const Severity = Ast.Diagnostic.Severity;

const MAX_OVERLOADS: u8 = 32;

fn anyLabeledSignature(func: Plugin.ExprFunc) bool {
    var it = func.signatureIter();
    while (it.next()) |sig| {
        if (sig.labeledEnabled()) return true;
    }
    return false;
}

fn overloadInitialMask(func: Plugin.ExprFunc, argc: usize) u32 {
    var mask: u32 = 0;
    var it = func.signatureIter();
    var i: u5 = 0;
    while (it.next()) |sig| : (i += 1) {
        if (i >= MAX_OVERLOADS) break;
        if (sig.checkArity(argc)) mask |= @as(u32, 1) << i;
    }
    return mask;
}

fn overloadAcceptMask(
    func: Plugin.ExprFunc,
    pos_idx: usize,
    kind: Ast.ValueKind,
) u32 {
    var accept: u32 = 0;
    var it = func.signatureIter();
    var i: u5 = 0;
    while (it.next()) |sig| : (i += 1) {
        if (i >= MAX_OVERLOADS) break;
        const bit = @as(u32, 1) << i;
        if (sig.paramType(pos_idx)) |t| {
            if (kindAcceptsType(kind, t)) accept |= bit;
        } else {
            accept |= bit;
        }
    }
    return accept;
}

fn kindAcceptsType(kind: Ast.ValueKind, expected: Plugin.ValueType) bool {
    return switch (expected) {
        .any, .named => true,
        .number => kind == .number or kind == .number_with_unit,
        .string => kind == .string,
        .symbol => kind == .symbol,
        .boolean => kind == .boolean,
        .nil => kind == .nil,
        .vector => kind == .vector,
        .form, .expr => kind == .form,
    };
}

fn kindLabel(kind: Ast.ValueKind) []const u8 {
    return switch (kind) {
        .nil => "nil",
        .boolean => "boolean",
        .number => "number",
        .number_with_unit => "number with unit",
        .date => "date",
        .time => "time",
        .string => "string",
        .keyword => "keyword",
        .symbol => "symbol",
        .vector => "vector",
        .form => "form",
    };
}

fn emitOverloadMismatch(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    span: Ast.Span,
    path: []const []const u8,
    func: Plugin.ExprFunc,
    pos_idx: usize,
    cand_mask: u32,
    actual_kind: Ast.ValueKind,
) Allocator.Error!void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "expression `");
    try buf.appendSlice(a, func.name);
    try buf.appendSlice(a, "` argument ");
    const piece = try std.fmt.allocPrint(a, "{d}", .{pos_idx});
    try buf.appendSlice(a, piece);
    try buf.appendSlice(a, " expects ");
    try describeOverloadTypes(a, &buf, func, pos_idx, cand_mask);
    try buf.appendSlice(a, ", got ");
    try buf.appendSlice(a, kindLabel(actual_kind));
    try emit(a, diags, span, path, .err, .expr_type_mismatch, try buf.toOwnedSlice(a));
}

fn describeOverloadTypes(
    a: Allocator,
    buf: *std.ArrayList(u8),
    func: Plugin.ExprFunc,
    pos_idx: usize,
    cand_mask: u32,
) Allocator.Error!void {
    var seen: [MAX_OVERLOADS]Plugin.ValueType = undefined;
    var n_seen: usize = 0;
    var it = func.signatureIter();
    var i: u5 = 0;
    while (it.next()) |sig| : (i += 1) {
        if (i >= MAX_OVERLOADS) break;
        if ((cand_mask & (@as(u32, 1) << i)) == 0) continue;
        const t = sig.paramType(pos_idx) orelse continue;
        var dup = false;
        for (seen[0..n_seen]) |s| if (valueTypesEqual(s, t)) {
            dup = true;
            break;
        };
        if (!dup and n_seen < seen.len) {
            seen[n_seen] = t;
            n_seen += 1;
        }
    }
    if (n_seen == 0) {
        try buf.appendSlice(a, "any value");
        return;
    }
    for (seen[0..n_seen], 0..) |t, idx| {
        if (idx > 0) try buf.appendSlice(a, " or ");
        try describeType(a, buf, t);
    }
}

fn valueTypesEqual(a: Plugin.ValueType, b: Plugin.ValueType) bool {
    if (@as(std.meta.Tag(Plugin.ValueType), a) != @as(std.meta.Tag(Plugin.ValueType), b)) return false;
    return switch (a) {
        .named => |n| qualifiedRefsEqual(n, b.named),
        else => true,
    };
}

fn qualifiedRefsEqual(a: Plugin.QualifiedRef, b: Plugin.QualifiedRef) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (a.namespace == null and b.namespace == null) return true;
    if (a.namespace == null or b.namespace == null) return false;
    return std.mem.eql(u8, a.namespace.?, b.namespace.?);
}

pub const FormExprResolution = union(enum) {
    data_form,
    expr: struct {
        func: *const Plugin.ExprFunc,
        result: ?Plugin.ValueType,
    },
    unresolved,
};

fn resolveFormExpression(
    a: Allocator,
    schema: Schema.Schema,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Allocator.Error!FormExprResolution {
    if (tree.tagOf(idx) != .form) return .unresolved;
    const hdr = tree.formHeader(idx);
    if (hdr.head.len == 0) return .unresolved;

    switch (schema.lookupForm(hdr.head, hdr.namespace)) {
        .found => return .data_form,
        .ambiguous => return .unresolved,
        .not_found => {},
    }

    switch (schema.lookupExprFunc(hdr.head, hdr.namespace)) {
        .not_found, .ambiguous => return .unresolved,
        .found => |hit| {
            if (hit.func.signatures == null) {
                return .{ .expr = .{ .func = hit.func, .result = hit.func.result } };
            }
            const resolved = try Schema.resolveExprArgs(a, hit.func.*, tree, hdr);
            switch (resolved) {
                .err => return .{ .expr = .{ .func = hit.func, .result = null } },
                .ok => |r| {
                    if (r.signature) |sig| {
                        return .{ .expr = .{ .func = hit.func, .result = sig.result } };
                    }
                    return .{ .expr = .{ .func = hit.func, .result = sharedResultByArity(hit.func.*, r.positional.len) } };
                },
            }
        },
    }
}

pub fn resolveFormExpressionBinary(
    schema: Schema.Schema,
    head: []const u8,
    namespace: ?[]const u8,
    argc: u32,
) FormExprResolution {
    if (head.len == 0) return .unresolved;
    switch (schema.lookupForm(head, namespace)) {
        .found => return .data_form,
        .ambiguous => return .unresolved,
        .not_found => {},
    }
    switch (schema.lookupExprFunc(head, namespace)) {
        .not_found, .ambiguous => return .unresolved,
        .found => |hit| {
            if (hit.func.signatures == null) {
                return .{ .expr = .{ .func = hit.func, .result = hit.func.result } };
            }
            return .{ .expr = .{ .func = hit.func, .result = sharedResultByArity(hit.func.*, argc) } };
        },
    }
}

fn sharedResultByArity(func: Plugin.ExprFunc, argc: usize) ?Plugin.ValueType {
    var shared: ?Plugin.ValueType = null;
    var have_one = false;
    var it = func.signatureIter();
    while (it.next()) |sig| {
        if (!sig.checkArity(argc)) continue;
        const r = sig.result orelse return null;
        if (!have_one) {
            shared = r;
            have_one = true;
            continue;
        }
        if (!valueTypesEqual(shared.?, r)) return null;
    }
    return shared;
}

pub const DeclaredTypeMatch = enum { yes, no, unknown };

pub fn declaredResultMatchesExpected(
    schema: Schema.Schema,
    actual: Plugin.ValueType,
    expected: Plugin.ValueType,
) DeclaredTypeMatch {
    if (isAnyType(expected)) return .yes;
    if (isAnyType(actual)) return .unknown;

    const a_norm = normalizeTypeName(actual);
    const e_norm = normalizeTypeName(expected);
    if (valueTypesEqual(a_norm, e_norm)) return .yes;

    const a_prim = primitiveOf(schema, a_norm) orelse return .unknown;
    const e_prim = primitiveOf(schema, e_norm) orelse return .unknown;
    if (a_prim != e_prim) return .no;

    if (e_norm == .named) {
        const k = switch (schema.lookupValueKind(e_norm.named.name, e_norm.named.namespace)) {
            .found => |kk| kk,
            else => return .unknown,
        };
        if (kindHasRefinements(k)) return .unknown;
    }
    return .yes;
}

fn isAnyType(vt: Plugin.ValueType) bool {
    return switch (vt) {
        .any => true,
        .named => |n| std.mem.eql(u8, n.name, "any"),
        else => false,
    };
}

fn normalizeTypeName(vt: Plugin.ValueType) Plugin.ValueType {
    return switch (vt) {
        .named => |n| resolvePrimitiveShortcut(n.name) orelse vt,
        else => vt,
    };
}

const PrimitiveUnderlying = enum { number, string, symbol, boolean, nil, vector };

fn primitiveOf(schema: Schema.Schema, vt: Plugin.ValueType) ?PrimitiveUnderlying {
    return switch (vt) {
        .number => .number,
        .string => .string,
        .symbol => .symbol,
        .boolean => .boolean,
        .nil => .nil,
        .vector => .vector,
        .any, .form, .expr => null,
        .named => |n| switch (schema.lookupValueKind(n.name, n.namespace)) {
            .found => |k| switch (k.underlying) {
                .number => .number,
                .string => .string,
                .symbol => .symbol,
                .vector => .vector,
                .form => null,
                .union_of => null,
            },
            else => null,
        },
    };
}

fn kindHasRefinements(k: *const Plugin.ValueKind) bool {
    if (k.vector) |_| return true;
    if (k.unit) |_| return true;
    if (k.members) |_| return true;
    if (k.heads) |_| return true;
    if (k.cross_ref) |_| return true;
    if (k.union_of) |_| return true;
    return false;
}

fn resolvesToUnion(schema: Schema.Schema, expected: Plugin.ValueType) bool {
    switch (expected) {
        .named => |n| switch (schema.lookupValueKind(n.name, n.namespace)) {
            .found => |k| return k.underlying == .union_of,
            else => return false,
        },
        else => return false,
    }
}

pub fn typeLabel(expected: Plugin.ValueType) []const u8 {
    return switch (expected) {
        .any => "any value",
        .number => "number",
        .string => "string",
        .symbol => "symbol",
        .boolean => "boolean",
        .nil => "nil",
        .vector => "vector",
        .form => "form",
        .expr => "expression",
        .named => |n| n.name,
    };
}

pub const Diagnostic = Ast.Diagnostic;

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    diagnostics: []const Diagnostic,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const Result) bool {
        for (self.diagnostics) |d| if (d.severity == .err) return true;
        return false;
    }
};

pub const Error = BinaryCursor.Error;

const Frame = struct {
    idx: Ast.NodeIndex,
    path: []const []const u8,
    scope_chain: []const ScopeFrame = &.{},
    parent_form_spec: ?*const Plugin.FormSpec = null,
    local_form_registry: ?[]const Plugin.FormSpec = null,
    local_form_slot_path: []const []const u8 = &.{},
};

pub const ScopeFrame = struct {
    canonical: []const u8,
    scope_id: ScopeId,
};

fn findNearestScope(chain: []const ScopeFrame, scope_form: []const u8) ?ScopeId {
    var i: usize = chain.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, chain[i].canonical, scope_form)) return chain[i].scope_id;
    }
    return null;
}

pub const ScopeId = enum(u64) {
    _,

    pub inline fn tree(tree_idx: u32) ScopeId {
        return @enumFromInt(@as(u64, tree_idx));
    }

    pub inline fn lexical(tree_idx: u32, lexical_id: u32) ScopeId {
        const v: u64 = (@as(u64, 1) << 63) | (@as(u64, lexical_id) << 32) | tree_idx;
        return @enumFromInt(v);
    }

    pub inline fn treeIdx(self: ScopeId) u32 {
        return @truncate(@intFromEnum(self));
    }

    pub inline fn isLexical(self: ScopeId) bool {
        return (@intFromEnum(self) >> 63) != 0;
    }
};

pub const CrossRefIndex = struct {
    by_scope: std.AutoHashMapUnmanaged(ScopeId, TargetMap) = .empty,
    references_by_scope: std.AutoHashMapUnmanaged(ScopeId, RefTargetMap) = .empty,
    arena: ?Allocator = null,

    pub const TargetMap = std.StringHashMapUnmanaged(NameMap);
    pub const NameMap = std.StringHashMapUnmanaged(Site);

    pub const RefTargetMap = std.StringHashMapUnmanaged(RefNameMap);
    pub const RefNameMap = std.StringHashMapUnmanaged(std.ArrayList(Site));

    pub const Site = struct {
        tree_idx: u32,
        node_idx: Ast.NodeIndex,
        form_span: Ast.Span,
        name_span: Ast.Span,
        scope: ScopeId,
    };

    pub fn isEmpty(self: *const CrossRefIndex) bool {
        return self.by_scope.count() == 0;
    }

    pub fn contains(
        self: *const CrossRefIndex,
        scope: ScopeId,
        target: []const u8,
        name: []const u8,
    ) bool {
        const tm = self.by_scope.getPtr(scope) orelse return false;
        const set = tm.getPtr(target) orelse return false;
        return set.contains(name);
    }

    pub fn lookup(
        self: *const CrossRefIndex,
        scope: ScopeId,
        target: []const u8,
        name: []const u8,
    ) ?Site {
        const tm = self.by_scope.getPtr(scope) orelse return null;
        const set = tm.getPtr(target) orelse return null;
        return set.get(name);
    }

    pub fn lookupReferences(
        self: *const CrossRefIndex,
        scope: ScopeId,
        target: []const u8,
        name: []const u8,
    ) []const Site {
        const tm = self.references_by_scope.getPtr(scope) orelse return &.{};
        const set = tm.getPtr(target) orelse return &.{};
        const list = set.getPtr(name) orelse return &.{};
        return list.items;
    }

    pub fn iterateNames(
        self: *const CrossRefIndex,
        scope: ScopeId,
        target: []const u8,
    ) NameMap.Iterator {
        const tm = self.by_scope.getPtr(scope) orelse return (NameMap{}).iterator();
        const set = tm.getPtr(target) orelse return (NameMap{}).iterator();
        return set.iterator();
    }

    pub fn appendReference(
        self: *CrossRefIndex,
        scope: ScopeId,
        target: []const u8,
        name: []const u8,
        site: Site,
    ) Allocator.Error!void {
        const a = self.arena orelse return;
        const scope_gop = try self.references_by_scope.getOrPut(a, scope);
        if (!scope_gop.found_existing) scope_gop.value_ptr.* = .empty;
        const target_gop = try scope_gop.value_ptr.getOrPut(a, target);
        if (!target_gop.found_existing) target_gop.value_ptr.* = .empty;
        const name_gop = try target_gop.value_ptr.getOrPut(a, name);
        if (!name_gop.found_existing) name_gop.value_ptr.* = .empty;
        try name_gop.value_ptr.append(a, site);
    }
};

pub const ForestResult = struct {
    results: []Result,
    cross_ref_index: CrossRefIndex,
    index_arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ForestResult, gpa: Allocator) void {
        for (self.results) |*r| r.deinit();
        gpa.free(self.results);
        self.index_arena.deinit();
        self.* = undefined;
    }

    pub fn intoSingle(self: *ForestResult, gpa: Allocator) Result {
        std.debug.assert(self.results.len == 1);
        const r = self.results[0];
        gpa.free(self.results);
        self.index_arena.deinit();
        self.* = undefined;
        return r;
    }
};

fn canonicalCrossRefTarget(
    a: Allocator,
    schema: Schema.Schema,
    target_form: []const u8,
) Allocator.Error!?[]const u8 {
    var ns: ?[]const u8 = null;
    var name = target_form;
    if (std.mem.indexOfScalar(u8, target_form, '/')) |slash| {
        ns = target_form[0..slash];
        name = target_form[slash + 1 ..];
    }
    const hit = switch (schema.lookupForm(name, ns)) {
        .found => |h| h,
        else => return null,
    };
    return try std.fmt.allocPrint(a, "{s}/{s}", .{ hit.plugin.name, hit.form.name });
}

fn canonicalFormNameBuf(
    a: Allocator,
    buf: *std.ArrayList(u8),
    schema: Schema.Schema,
    head: []const u8,
    namespace: ?[]const u8,
) Allocator.Error!?[]const u8 {
    const hit = switch (schema.lookupForm(head, namespace)) {
        .found => |h| h,
        else => return null,
    };
    buf.clearRetainingCapacity();
    try buf.appendSlice(a, hit.plugin.name);
    try buf.append(a, '/');
    try buf.appendSlice(a, hit.form.name);
    return buf.items;
}

const CycleCtx = struct {
    specs: []Schema.AcyclicSpec,
    nodes_by_scope: []std.AutoHashMapUnmanaged(ScopeId, std.ArrayList(Node)),

    const Node = struct {
        name: []const u8,
        tree_idx: u32,
        name_span: Ast.Span,
        edges: []const []const u8,
    };

    fn init(
        gpa: Allocator,
        index_a: Allocator,
        schema: Schema.Schema,
    ) Allocator.Error!CycleCtx {
        const specs = try Schema.collectAcyclicSpecs(schema, gpa);
        errdefer Schema.freeAcyclicSpecs(gpa, specs);
        const maps = try index_a.alloc(std.AutoHashMapUnmanaged(ScopeId, std.ArrayList(Node)), specs.len);
        for (maps) |*m| m.* = .empty;
        return .{ .specs = specs, .nodes_by_scope = maps };
    }

    fn deinit(self: *CycleCtx, gpa: Allocator) void {
        Schema.freeAcyclicSpecs(gpa, self.specs);
    }

    fn isEmpty(self: *const CycleCtx) bool {
        return self.specs.len == 0;
    }

    fn specForCanonical(self: *const CycleCtx, canonical: []const u8) ?u32 {
        for (self.specs, 0..) |s, i| {
            if (std.mem.eql(u8, s.target_form, canonical)) return @intCast(i);
        }
        return null;
    }

    fn edgeShape(self: *const CycleCtx, spec_idx: u32, key: []const u8) ?Schema.EdgeShape {
        for (self.specs[spec_idx].edges) |e| {
            if (std.mem.eql(u8, e.name, key)) return e.shape;
        }
        return null;
    }

    fn appendNode(
        self: *CycleCtx,
        index_a: Allocator,
        spec_idx: u32,
        scope: ScopeId,
        name: []const u8,
        tree_idx: u32,
        name_span: Ast.Span,
        edges: []const []const u8,
    ) Allocator.Error!void {
        const gop = try self.nodes_by_scope[spec_idx].getOrPut(index_a, scope);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(index_a, .{
            .name = name,
            .tree_idx = tree_idx,
            .name_span = name_span,
            .edges = edges,
        });
    }
};

pub const CrossRefSpec = struct {
    name_key: []const u8,
    scope_form: ?[]const u8,
};

fn collectCrossRefTargets(
    index_a: Allocator,
    schema: Schema.Schema,
) Allocator.Error!std.StringHashMapUnmanaged(CrossRefSpec) {
    var targets: std.StringHashMapUnmanaged(CrossRefSpec) = .empty;
    errdefer targets.deinit(index_a);
    for (schema.plugins) |*plugin| {
        for (plugin.value_kinds) |*kind| {
            const cr = kind.cross_ref orelse continue;
            const canonical = (try canonicalCrossRefTarget(index_a, schema, cr.target_form)) orelse continue;
            const scope_canonical: ?[]const u8 = if (cr.scope_form) |sf|
                try canonicalCrossRefTarget(index_a, schema, sf)
            else
                null;
            const gop = try targets.getOrPut(index_a, canonical);
            if (!gop.found_existing) gop.value_ptr.* = .{
                .name_key = cr.name_key,
                .scope_form = scope_canonical,
            };
        }
    }
    return targets;
}

fn collectScopeHeads(
    index_a: Allocator,
    targets: *const std.StringHashMapUnmanaged(CrossRefSpec),
) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var heads: std.StringHashMapUnmanaged(void) = .empty;
    errdefer heads.deinit(index_a);
    var it = targets.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.scope_form) |sf| {
            try heads.put(index_a, sf, {});
        }
    }
    return heads;
}

fn schemaScopeHeads(
    a: Allocator,
    schema: Schema.Schema,
) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var heads: std.StringHashMapUnmanaged(void) = .empty;
    errdefer freeSchemaScopeHeads(a, &heads);
    for (schema.plugins) |*plugin| {
        for (plugin.value_kinds) |*kind| {
            const cr = kind.cross_ref orelse continue;
            const scope = cr.scope_form orelse continue;
            const canonical = (try canonicalCrossRefTarget(a, schema, scope)) orelse continue;
            const gop = try heads.getOrPut(a, canonical);
            if (gop.found_existing) a.free(canonical);
        }
    }
    return heads;
}

fn freeSchemaScopeHeads(a: Allocator, heads: *std.StringHashMapUnmanaged(void)) void {
    var it = heads.keyIterator();
    while (it.next()) |k| a.free(k.*);
    heads.deinit(a);
}

const SCOPE_POP_SENTINEL: Ast.NodeIndex = .invalid;

fn buildCrossRefIndexForest(
    index_a: Allocator,
    gpa: Allocator,
    schema: Schema.Schema,
    trees: []const Ast.Tree,
    results: []Result,
    diags_lists: []std.ArrayList(Diagnostic),
    options: Options,
) Allocator.Error!CrossRefIndex {
    var targets = try collectCrossRefTargets(index_a, schema);
    defer targets.deinit(index_a);
    var scope_heads = try collectScopeHeads(index_a, &targets);
    defer scope_heads.deinit(index_a);

    var cycle_ctx = try CycleCtx.init(gpa, index_a, schema);
    defer cycle_ctx.deinit(gpa);

    var index: CrossRefIndex = .{ .arena = index_a };
    if (targets.count() == 0 and cycle_ctx.isEmpty()) return index;

    var stack: std.ArrayList(Ast.NodeIndex) = .empty;
    defer stack.deinit(gpa);
    var canon_buf: std.ArrayList(u8) = .empty;
    defer canon_buf.deinit(gpa);
    var scope_stack: std.ArrayList(ScopeFrame) = .empty;
    defer scope_stack.deinit(gpa);

    for (trees, 0..) |*tree, t| {
        stack.clearRetainingCapacity();
        scope_stack.clearRetainingCapacity();
        const t_idx: u32 = @intCast(t);
        const tree_scope: ScopeId = if (options.share_scope) .tree(0) else .tree(t_idx);
        const tree_a = results[t].arena.allocator();
        const tree_options = perTreeOptions(options, t);

        var ri: usize = tree.root.len;
        while (ri > 0) : (ri -= 1) try stack.append(gpa, tree.root[ri - 1]);

        while (stack.pop()) |idx| {
            if (idx == SCOPE_POP_SENTINEL) {
                _ = scope_stack.pop();
                continue;
            }
            switch (tree.tagOf(idx)) {
                .form => {
                    const hdr = tree.formHeader(idx);
                    const canonical = try canonicalFormNameBuf(gpa, &canon_buf, schema, hdr.head, hdr.namespace);
                    if (canonical) |canon| {
                        if (targets.getEntry(canon)) |entry| {
                            const spec = entry.value_ptr.*;
                            const reg_scope = if (spec.scope_form) |sf|
                                findNearestScope(scope_stack.items, sf) orelse tree_scope
                            else
                                tree_scope;
                            try registerCrossRefInstance(
                                index_a,
                                tree_a,
                                &index,
                                &cycle_ctx,
                                tree,
                                t_idx,
                                reg_scope,
                                idx,
                                hdr,
                                entry.key_ptr.*,
                                spec.name_key,
                                &diags_lists[t],
                                tree_options,
                            );
                        }
                        if (scope_heads.getEntry(canon)) |sh_entry| {
                            const lexical_id: u32 = @intFromEnum(idx);
                            try scope_stack.append(gpa, .{
                                .canonical = sh_entry.key_ptr.*,
                                .scope_id = .lexical(t_idx, lexical_id),
                            });
                            try stack.append(gpa, SCOPE_POP_SENTINEL);
                        }
                    }
                    var ci: usize = hdr.children.len;
                    while (ci > 0) : (ci -= 1) try stack.append(gpa, hdr.children[ci - 1]);
                },
                .vector => {
                    const elements = tree.vectorElements(idx);
                    var ci: usize = elements.len;
                    while (ci > 0) : (ci -= 1) try stack.append(gpa, elements[ci - 1]);
                },
                .kvpair => {
                    const kvh = tree.kvpairHeader(idx);
                    try stack.append(gpa, kvh.value);
                },
                else => {},
            }
        }
    }

    if (!cycle_ctx.isEmpty()) {
        try runAcyclicCheck(gpa, &cycle_ctx, results, diags_lists);
    }

    return index;
}

fn registerCrossRefInstance(
    index_a: Allocator,
    tree_a: Allocator,
    index: *CrossRefIndex,
    cycle_ctx: *CycleCtx,
    tree: *const Ast.Tree,
    tree_idx: u32,
    scope: ScopeId,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    canonical_target: []const u8,
    name_key: []const u8,
    diags: *std.ArrayList(Diagnostic),
    options: Options,
) Allocator.Error!void {
    for (hdr.children) |ch| {
        if (tree.tagOf(ch) != .kvpair) continue;
        const kv = tree.kvpairHeader(ch);
        if (!std.mem.eql(u8, kv.key, name_key)) continue;
        if (tree.tagOf(kv.value) != .symbol) return;

        const name_text = tree.symbolText(kv.value);
        try registerName(
            index_a,
            tree_a,
            index,
            cycle_ctx,
            tree,
            tree_idx,
            scope,
            form_idx,
            hdr,
            canonical_target,
            name_text,
            tree.spanOf(kv.value),
            diags,
        );
        return;
    }

    if (options.axes.name_index) if (options.overlay) |overlay| {
        const entry = overlay.defaultFor(form_idx, name_key) orelse return;
        const text = switch (entry.value) {
            .keyword => |k| k,
            .string => |s| s,
            else => return,
        };
        try registerName(
            index_a,
            tree_a,
            index,
            cycle_ctx,
            tree,
            tree_idx,
            scope,
            form_idx,
            hdr,
            canonical_target,
            text,
            hdr.head_span,
            diags,
        );
    };
}

fn registerName(
    index_a: Allocator,
    tree_a: Allocator,
    index: *CrossRefIndex,
    cycle_ctx: *CycleCtx,
    tree: *const Ast.Tree,
    tree_idx: u32,
    scope: ScopeId,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    canonical_target: []const u8,
    name_text: []const u8,
    name_span: Ast.Span,
    diags: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    const scope_gop = try index.by_scope.getOrPut(index_a, scope);
    if (!scope_gop.found_existing) scope_gop.value_ptr.* = .empty;
    const target_gop = try scope_gop.value_ptr.getOrPut(index_a, canonical_target);
    if (!target_gop.found_existing) target_gop.value_ptr.* = .empty;
    const set = target_gop.value_ptr;
    const gop = try set.getOrPut(index_a, name_text);
    if (gop.found_existing) {
        try emitDuplicateCrossRef(
            tree_a,
            diags,
            name_span,
            canonical_target,
            name_text,
        );
        return;
    }
    gop.value_ptr.* = .{
        .tree_idx = tree_idx,
        .node_idx = form_idx,
        .form_span = tree.spanOf(form_idx),
        .name_span = name_span,
        .scope = scope,
    };

    if (cycle_ctx.specForCanonical(canonical_target)) |spec_idx| {
        try captureTreeEdges(
            index_a,
            cycle_ctx,
            spec_idx,
            scope,
            tree,
            tree_idx,
            hdr,
            name_text,
            name_span,
        );
    }
}

fn captureTreeEdges(
    index_a: Allocator,
    ctx: *CycleCtx,
    spec_idx: u32,
    scope: ScopeId,
    tree: *const Ast.Tree,
    tree_idx: u32,
    hdr: Ast.FormHeader,
    name_text: []const u8,
    name_span: Ast.Span,
) Allocator.Error!void {
    var edges: std.ArrayList([]const u8) = .empty;
    errdefer edges.deinit(index_a);

    for (hdr.children) |ch| {
        if (tree.tagOf(ch) != .kvpair) continue;
        const kv = tree.kvpairHeader(ch);
        const shape = ctx.edgeShape(spec_idx, kv.key) orelse continue;
        switch (shape) {
            .scalar => {
                if (tree.tagOf(kv.value) == .symbol) {
                    try edges.append(index_a, tree.symbolText(kv.value));
                }
            },
            .vector => {
                if (tree.tagOf(kv.value) == .vector) {
                    for (tree.vectorElements(kv.value)) |elem| {
                        if (tree.tagOf(elem) == .symbol) {
                            try edges.append(index_a, tree.symbolText(elem));
                        }
                    }
                }
            },
        }
    }

    try ctx.appendNode(
        index_a,
        spec_idx,
        scope,
        name_text,
        tree_idx,
        name_span,
        try edges.toOwnedSlice(index_a),
    );
}

fn runAcyclicCheck(
    gpa: Allocator,
    ctx: *CycleCtx,
    results: []Result,
    diags_lists: []std.ArrayList(Diagnostic),
) Allocator.Error!void {
    for (ctx.specs, 0..) |spec, spec_idx| {
        var it = ctx.nodes_by_scope[spec_idx].iterator();
        while (it.next()) |entry| {
            const nodes = entry.value_ptr.items;
            if (nodes.len == 0) continue;
            try runAcyclicSpec(gpa, spec, nodes, results, diags_lists);
        }
    }
}

fn runAcyclicSpec(
    gpa: Allocator,
    spec: Schema.AcyclicSpec,
    nodes: []const CycleCtx.Node,
    results: []Result,
    diags_lists: []std.ArrayList(Diagnostic),
) Allocator.Error!void {
    const Emit = struct {
        gpa: Allocator,
        kind_name: []const u8,
        results: []Result,
        diags_lists: []std.ArrayList(Diagnostic),

        fn onCycle(
            self: @This(),
            ns: []const CycleCtx.Node,
            cycle: []const DfsFrame,
        ) Allocator.Error!void {
            try emitCyclicCrossRef(
                self.gpa,
                self.results,
                self.diags_lists,
                self.kind_name,
                ns,
                cycle,
            );
        }
    };

    try detectGraphCycles(CycleCtx.Node, gpa, nodes, Emit{
        .gpa = gpa,
        .kind_name = spec.kind_name,
        .results = results,
        .diags_lists = diags_lists,
    }, Emit.onCycle);
}

const COLOR_WHITE: u8 = 0;
const COLOR_GRAY: u8 = 1;
const COLOR_BLACK: u8 = 2;
pub const DfsFrame = struct { node_idx: u32, edge_idx: u32 };

pub fn detectGraphCycles(
    comptime Node: type,
    gpa: Allocator,
    nodes: []const Node,
    ctx: anytype,
    comptime onCycle: anytype,
) Allocator.Error!void {
    var color = try gpa.alloc(u8, nodes.len);
    defer gpa.free(color);
    @memset(color, COLOR_WHITE);

    var stack: std.ArrayList(DfsFrame) = .empty;
    defer stack.deinit(gpa);

    for (0..nodes.len) |start| {
        if (color[start] != COLOR_WHITE) continue;
        color[start] = COLOR_GRAY;
        try stack.append(gpa, .{ .node_idx = @intCast(start), .edge_idx = 0 });

        while (stack.items.len > 0) {
            const top = stack.items.len - 1;
            const frame = &stack.items[top];
            const node = nodes[frame.node_idx];

            if (frame.edge_idx >= node.edges.len) {
                color[frame.node_idx] = COLOR_BLACK;
                _ = stack.pop();
                continue;
            }

            const edge_target = node.edges[frame.edge_idx];
            frame.edge_idx += 1;

            const target_idx = lookupGraphNodeIdx(Node, nodes, edge_target) orelse continue;
            const tc = color[target_idx];
            if (tc == COLOR_BLACK) continue;
            if (tc == COLOR_GRAY) {
                var start_idx: usize = stack.items.len;
                for (stack.items, 0..) |sf, i| {
                    if (sf.node_idx == target_idx) {
                        start_idx = i;
                        break;
                    }
                }
                if (start_idx < stack.items.len) {
                    try onCycle(ctx, nodes, stack.items[start_idx..]);
                }
                continue;
            }
            color[target_idx] = COLOR_GRAY;
            try stack.append(gpa, .{ .node_idx = target_idx, .edge_idx = 0 });
        }
    }
}

fn lookupGraphNodeIdx(comptime Node: type, nodes: []const Node, name: []const u8) ?u32 {
    for (nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.name, name)) return @intCast(i);
    }
    return null;
}

fn emitCyclicCrossRef(
    gpa: Allocator,
    results: []Result,
    diags_lists: []std.ArrayList(Diagnostic),
    kind_name: []const u8,
    nodes: []const CycleCtx.Node,
    cycle: []const DfsFrame,
) Allocator.Error!void {
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);
    for (cycle, 0..) |sf, i| {
        if (i > 0) try path_buf.appendSlice(gpa, " -> ");
        try path_buf.appendSlice(gpa, nodes[sf.node_idx].name);
    }
    try path_buf.appendSlice(gpa, " -> ");
    try path_buf.appendSlice(gpa, nodes[cycle[0].node_idx].name);

    for (cycle) |sf| {
        const node = nodes[sf.node_idx];
        const tree_a = results[node.tree_idx].arena.allocator();
        const message = try std.fmt.allocPrint(
            tree_a,
            "cyclic reference through `{s}` cross-ref: `{s}`",
            .{ kind_name, path_buf.items },
        );
        try diags_lists[node.tree_idx].append(tree_a, .{
            .span = node.name_span,
            .message = message,
            .severity = .err,
            .code = .cyclic_cross_ref,
            .path = &.{},
        });
    }
}

fn emitDuplicateCrossRef(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    span: Ast.Span,
    target: []const u8,
    name: []const u8,
) Allocator.Error!void {
    const message = try std.fmt.allocPrint(
        a,
        "duplicate cross-ref name `{s}` on form `{s}`",
        .{ name, target },
    );
    try diags.append(a, .{
        .span = span,
        .message = message,
        .severity = .err,
        .code = .duplicate_cross_ref_target,
        .path = &.{},
    });
}

const IndexFrame = union(enum) {
    form_iter: FormIndexFrame,
    vector_iter: VectorIndexFrame,
};

const FormIndexFrame = struct {
    head: []const u8,
    canonical_target: ?[]const u8,
    name_key: ?[]const u8,
    form_span: Ast.Span,
    iter: BinaryCursor.ChildIter,
    captured_name: ?[]const u8 = null,
    captured_span: Ast.Span = ZERO_SPAN,
    saw_name_kvpair: bool = false,
    acyclic_spec_idx: ?u32 = null,
    scope: ScopeId,
    opened_scope: bool = false,
    captured_edges: std.ArrayList([]const u8) = .empty,
};

const VectorIndexFrame = struct {
    iter: BinaryCursor.VectorIter,
    edge_capture: ?EdgeCapture = null,

    const EdgeCapture = struct {
        parent_form_idx: u32,
    };
};

fn buildCrossRefIndexBinary(
    index_a: Allocator,
    gpa: Allocator,
    schema: Schema.Schema,
    binaries: []const []const u8,
    results: []Result,
    diags_lists: []std.ArrayList(Diagnostic),
) Error!CrossRefIndex {
    var targets = try collectCrossRefTargets(index_a, schema);
    defer targets.deinit(index_a);
    var scope_heads = try collectScopeHeads(index_a, &targets);
    defer scope_heads.deinit(index_a);

    var cycle_ctx = try CycleCtx.init(gpa, index_a, schema);
    defer cycle_ctx.deinit(gpa);

    var index: CrossRefIndex = .{ .arena = index_a };
    if (targets.count() == 0 and cycle_ctx.isEmpty()) return index;

    var frames: std.ArrayList(IndexFrame) = .empty;
    defer frames.deinit(gpa);
    var canon_buf: std.ArrayList(u8) = .empty;
    defer canon_buf.deinit(gpa);
    var scope_stack: std.ArrayList(ScopeFrame) = .empty;
    defer scope_stack.deinit(gpa);

    for (binaries, 0..) |bytes, b| {
        const t_idx: u32 = @intCast(b);
        const tree_scope: ScopeId = .tree(t_idx);
        const tree_a = results[b].arena.allocator();
        var cursor = try BinaryCursor.Cursor.init(bytes);
        var root_iter = try cursor.rootIter();
        scope_stack.clearRetainingCapacity();

        while (try root_iter.next()) |root_view| {
            try dispatchIndexValue(gpa, &canon_buf, schema, &cursor, root_view, &targets, &scope_heads, &cycle_ctx, &frames, &scope_stack, t_idx, tree_scope);

            var step: u32 = 0;
            while (frames.items.len > 0) {
                if (step >= MAX_VALIDATE_STEPS) return error.DepthExceeded;
                if (frames.items.len > MAX_VALIDATE_FRAMES) return error.DepthExceeded;
                step += 1;

                const top = frames.items.len - 1;
                switch (frames.items[top]) {
                    .form_iter => {
                        const fi = &frames.items[top].form_iter;
                        if (fi.iter.remaining == 0) {
                            _ = try fi.iter.next();
                            if (fi.captured_name) |nt| {
                                if (fi.canonical_target) |canon| {
                                    try registerCrossRefBinary(
                                        index_a,
                                        tree_a,
                                        &index,
                                        &cycle_ctx,
                                        fi.acyclic_spec_idx,
                                        canon,
                                        nt,
                                        fi.captured_span,
                                        fi.form_span,
                                        t_idx,
                                        fi.scope,
                                        fi.captured_edges.items,
                                        &diags_lists[b],
                                    );
                                }
                            }
                            if (fi.opened_scope) _ = scope_stack.pop();
                            _ = frames.pop();
                            continue;
                        }

                        const entry = (try fi.iter.next()) orelse unreachable;
                        const matches_name = fi.name_key != null and
                            !fi.saw_name_kvpair and
                            entry.kind == .keyword and
                            std.mem.eql(u8, entry.key.?, fi.name_key.?);

                        if (matches_name) {
                            fi.saw_name_kvpair = true;
                            if (entry.value.kind == .symbol) {
                                fi.captured_name = try BinaryCursor.readSymbol(&cursor, entry.value);
                                fi.captured_span = entry.value.span orelse ZERO_SPAN;
                                continue;
                            }
                        }

                        if (fi.acyclic_spec_idx) |spec_idx| {
                            if (entry.kind == .keyword) {
                                if (cycle_ctx.edgeShape(spec_idx, entry.key.?)) |shape| {
                                    if (try captureBinaryEdge(
                                        index_a,
                                        gpa,
                                        &cursor,
                                        shape,
                                        entry.value,
                                        fi,
                                        @intCast(top),
                                        &frames,
                                    )) continue;
                                }
                            }
                        }

                        try dispatchIndexValue(gpa, &canon_buf, schema, &cursor, entry.value, &targets, &scope_heads, &cycle_ctx, &frames, &scope_stack, t_idx, tree_scope);
                    },
                    .vector_iter => {
                        const vi = &frames.items[top].vector_iter;
                        if (vi.iter.remaining == 0) {
                            _ = frames.pop();
                            continue;
                        }
                        const ev = (try vi.iter.next()) orelse unreachable;
                        if (vi.edge_capture) |ec| {
                            if (ev.kind == .symbol) {
                                const sym = try BinaryCursor.readSymbol(&cursor, ev);
                                const fp = &frames.items[ec.parent_form_idx].form_iter;
                                try fp.captured_edges.append(index_a, sym);
                                continue;
                            }
                        }
                        try dispatchIndexValue(gpa, &canon_buf, schema, &cursor, ev, &targets, &scope_heads, &cycle_ctx, &frames, &scope_stack, t_idx, tree_scope);
                    },
                }
            }
        }
    }

    if (!cycle_ctx.isEmpty()) {
        try runAcyclicCheck(gpa, &cycle_ctx, results, diags_lists);
    }

    return index;
}

fn captureBinaryEdge(
    index_a: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    shape: Schema.EdgeShape,
    value: BinaryCursor.NodeView,
    parent_fi: *FormIndexFrame,
    parent_form_idx: u32,
    frames: *std.ArrayList(IndexFrame),
) Error!bool {
    switch (shape) {
        .scalar => {
            if (value.kind == .symbol) {
                const sym = try BinaryCursor.readSymbol(cursor, value);
                try parent_fi.captured_edges.append(index_a, sym);
                return true;
            }
            return false;
        },
        .vector => {
            if (value.kind == .vector) {
                const it = try BinaryCursor.readVector(cursor, value);
                try frames.append(gpa, .{ .vector_iter = .{
                    .iter = it,
                    .edge_capture = .{ .parent_form_idx = parent_form_idx },
                } });
                return true;
            }
            return false;
        },
    }
}

fn dispatchIndexValue(
    gpa: Allocator,
    canon_buf: *std.ArrayList(u8),
    schema: Schema.Schema,
    cursor: *BinaryCursor.Cursor,
    view: BinaryCursor.NodeView,
    targets: *const std.StringHashMapUnmanaged(CrossRefSpec),
    scope_heads: *const std.StringHashMapUnmanaged(void),
    cycle_ctx: *const CycleCtx,
    frames: *std.ArrayList(IndexFrame),
    scope_stack: *std.ArrayList(ScopeFrame),
    tree_idx: u32,
    tree_scope: ScopeId,
) Error!void {
    switch (view.kind) {
        .form => {
            const fv = try BinaryCursor.readForm(cursor, view);
            const form_pos: u32 = @intCast(cursor.pos);
            const canon_slice = try canonicalFormNameBuf(gpa, canon_buf, schema, fv.head, fv.namespace);
            var canonical_target: ?[]const u8 = null;
            var name_key: ?[]const u8 = null;
            var spec_idx: ?u32 = null;
            var reg_scope: ScopeId = tree_scope;
            var opened_scope: bool = false;
            if (canon_slice) |c| {
                if (targets.getEntry(c)) |entry| {
                    canonical_target = entry.key_ptr.*;
                    const spec = entry.value_ptr.*;
                    name_key = spec.name_key;
                    reg_scope = if (spec.scope_form) |sf|
                        findNearestScope(scope_stack.items, sf) orelse tree_scope
                    else
                        tree_scope;
                }
                spec_idx = cycle_ctx.specForCanonical(c);
                if (scope_heads.getEntry(c)) |sh_entry| {
                    try scope_stack.append(gpa, .{
                        .canonical = sh_entry.key_ptr.*,
                        .scope_id = .lexical(tree_idx, form_pos),
                    });
                    opened_scope = true;
                }
            }
            try frames.append(gpa, .{ .form_iter = .{
                .head = fv.head,
                .canonical_target = canonical_target,
                .name_key = name_key,
                .form_span = view.span orelse ZERO_SPAN,
                .iter = fv.children,
                .acyclic_spec_idx = spec_idx,
                .scope = reg_scope,
                .opened_scope = opened_scope,
            } });
        },
        .vector => {
            const it = try BinaryCursor.readVector(cursor, view);
            try frames.append(gpa, .{ .vector_iter = .{ .iter = it } });
        },
        else => try BinaryCursor.skipBody(cursor, view),
    }
}

fn registerCrossRefBinary(
    index_a: Allocator,
    tree_a: Allocator,
    index: *CrossRefIndex,
    cycle_ctx: *CycleCtx,
    spec_idx: ?u32,
    canonical_target: []const u8,
    name_text: []const u8,
    name_span: Ast.Span,
    form_span: Ast.Span,
    tree_idx: u32,
    scope: ScopeId,
    captured_edges: []const []const u8,
    diags: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    const scope_gop = try index.by_scope.getOrPut(index_a, scope);
    if (!scope_gop.found_existing) scope_gop.value_ptr.* = .empty;
    const target_gop = try scope_gop.value_ptr.getOrPut(index_a, canonical_target);
    if (!target_gop.found_existing) target_gop.value_ptr.* = .empty;
    const set = target_gop.value_ptr;
    const gop = try set.getOrPut(index_a, name_text);
    if (gop.found_existing) {
        try emitDuplicateCrossRef(tree_a, diags, name_span, canonical_target, name_text);
        return;
    }
    gop.value_ptr.* = .{
        .tree_idx = tree_idx,
        .node_idx = .invalid,
        .form_span = form_span,
        .name_span = name_span,
        .scope = scope,
    };
    if (spec_idx) |idx| {
        try cycle_ctx.appendNode(
            index_a,
            idx,
            scope,
            name_text,
            tree_idx,
            name_span,
            captured_edges,
        );
    }
}

pub fn validate(
    gpa: Allocator,
    tree: Ast.Tree,
    schema: Schema.Schema,
) Allocator.Error!Result {
    return validateWithOptions(gpa, tree, schema, .{});
}

pub fn validateWithOptions(
    gpa: Allocator,
    tree: Ast.Tree,
    schema: Schema.Schema,
    options: Options,
) Allocator.Error!Result {
    var trees: [1]Ast.Tree = .{tree};
    var fr = try validateForestWithOptions(gpa, &trees, schema, options);
    return fr.intoSingle(gpa);
}

pub fn validateForest(
    gpa: Allocator,
    trees: []const Ast.Tree,
    schema: Schema.Schema,
) Allocator.Error!ForestResult {
    return validateForestWithOptions(gpa, trees, schema, .{});
}

pub fn validateForestWithOptions(
    gpa: Allocator,
    trees: []const Ast.Tree,
    schema: Schema.Schema,
    options: Options,
) Allocator.Error!ForestResult {
    if (options.overlays) |ovs| std.debug.assert(ovs.len == trees.len);

    var index_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer index_arena.deinit();

    var results = try gpa.alloc(Result, trees.len);
    errdefer gpa.free(results);

    var inited: usize = 0;
    errdefer for (results[0..inited]) |*r| r.arena.deinit();
    for (0..trees.len) |i| {
        results[i] = .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .diagnostics = &.{},
        };
        inited = i + 1;
    }

    var diags_lists = try gpa.alloc(std.ArrayList(Diagnostic), trees.len);
    defer gpa.free(diags_lists);
    for (0..trees.len) |i| diags_lists[i] = .empty;

    var index = try buildCrossRefIndexForest(
        index_arena.allocator(),
        gpa,
        schema,
        trees,
        results,
        diags_lists,
        options,
    );

    var scope_heads_validation = try schemaScopeHeads(gpa, schema);
    defer freeSchemaScopeHeads(gpa, &scope_heads_validation);

    for (trees, 0..) |*tree, i| {
        const tree_scope: ScopeId = if (options.share_scope) .tree(0) else .tree(@intCast(i));
        try validateOneTree(
            results[i].arena.allocator(),
            gpa,
            schema,
            &index,
            tree,
            tree_scope,
            &scope_heads_validation,
            &diags_lists[i],
            perTreeOptions(options, i),
        );
    }

    for (0..trees.len) |i| {
        results[i].diagnostics = diags_lists[i].items;
    }

    return .{
        .results = results,
        .cross_ref_index = index,
        .index_arena = index_arena,
    };
}

fn validateOneTree(
    a: Allocator,
    gpa: Allocator,
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree: *const Ast.Tree,
    tree_scope: ScopeId,
    scope_heads: *const std.StringHashMapUnmanaged(void),
    diags: *std.ArrayList(Diagnostic),
    options: Options,
) Allocator.Error!void {
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    var canon_buf: std.ArrayList(u8) = .empty;
    defer canon_buf.deinit(gpa);

    var i: usize = tree.root.len;
    while (i > 0) : (i -= 1) {
        const idx = tree.root[i - 1];
        const path = try initialPath(a, tree, idx);
        try stack.append(gpa, .{ .idx = idx, .path = path, .scope_chain = &.{} });
    }

    outer: while (stack.pop()) |frame| {
        switch (tree.tagOf(frame.idx)) {
            .form => {
                const hdr = tree.formHeader(frame.idx);
                const local_hit: ?*const Plugin.FormSpec = blk: {
                    const reg = frame.local_form_registry orelse break :blk null;
                    if (hdr.namespace != null) break :blk null;
                    for (reg) |*lf| {
                        if (std.mem.eql(u8, lf.name, hdr.head)) break :blk lf;
                    }
                    break :blk null;
                };
                try validateFormHead(a, diags, schema, cross_index, tree_scope, frame.scope_chain, tree, frame.idx, frame.path, options, frame.local_form_registry, frame.local_form_slot_path, local_hit);
                var child_chain = frame.scope_chain;
                if (scope_heads.count() > 0) {
                    if (try canonicalFormNameBuf(gpa, &canon_buf, schema, hdr.head, hdr.namespace)) |canon| {
                        if (scope_heads.getEntry(canon)) |sh_entry| {
                            const tree_idx = tree_scope.treeIdx();
                            const new_chain = try a.alloc(ScopeFrame, frame.scope_chain.len + 1);
                            @memcpy(new_chain[0..frame.scope_chain.len], frame.scope_chain);
                            new_chain[frame.scope_chain.len] = .{
                                .canonical = sh_entry.key_ptr.*,
                                .scope_id = .lexical(tree_idx, @intFromEnum(frame.idx)),
                            };
                            child_chain = new_chain;
                        }
                    }
                }
                const child_spec: ?*const Plugin.FormSpec = if (local_hit) |lf|
                    lf
                else switch (schema.lookupForm(hdr.head, hdr.namespace)) {
                    .found => |hit| hit.form,
                    else => null,
                };
                var j: usize = hdr.children.len;
                while (j > 0) : (j -= 1) {
                    const ch = hdr.children[j - 1];
                    const step = try childStep(a, tree, ch, hdr.children, j - 1);
                    const child_path = try extendPath(a, frame.path, step);
                    try stack.append(gpa, .{
                        .idx = ch,
                        .path = child_path,
                        .scope_chain = child_chain,
                        .parent_form_spec = child_spec,
                    });
                }
            },
            .vector => {
                const elements = tree.vectorElements(frame.idx);
                var j: usize = elements.len;
                while (j > 0) : (j -= 1) {
                    const elem = elements[j - 1];
                    const step = try indexStep(a, j - 1);
                    const child_path = try extendPath(a, frame.path, step);
                    try stack.append(gpa, .{ .idx = elem, .path = child_path, .scope_chain = frame.scope_chain });
                }
            },
            .kvpair => {
                const kvh = tree.kvpairHeader(frame.idx);
                var local_registry: ?[]const Plugin.FormSpec = null;
                if (frame.parent_form_spec) |spec| {
                    const matched: ?Plugin.KeySpec = blk: {
                        for (spec.keys) |k| {
                            if (std.mem.eql(u8, k.name, kvh.key)) break :blk k;
                        }
                        if (spec.variants) |variants| {
                            for (variants) |v| {
                                for (v.keys) |k| {
                                    if (std.mem.eql(u8, k.name, kvh.key)) break :blk k;
                                }
                            }
                        }
                        break :blk null;
                    };
                    if (matched) |k| {
                        if (k.walk_opaque) continue :outer;
                        if (k.local_forms.len > 0 and tree.tagOf(kvh.value) == .form) {
                            local_registry = k.local_forms;
                        }
                    }
                }
                var child_path = frame.path;
                if (tree.tagOf(kvh.value) == .form) {
                    const v_hdr = tree.formHeader(kvh.value);
                    if (v_hdr.head.len > 0) {
                        const step = try a.dupe(u8, v_hdr.head);
                        child_path = try extendPath(a, frame.path, step);
                    }
                }
                try stack.append(gpa, .{
                    .idx = kvh.value,
                    .path = child_path,
                    .scope_chain = frame.scope_chain,
                    .local_form_registry = local_registry,
                    .local_form_slot_path = if (local_registry != null) frame.path else &.{},
                });
            },
            else => {},
        }
    }
}

fn initialPath(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Allocator.Error![]const []const u8 {
    if (tree.tagOf(idx) != .form) return &.{};
    const hdr = tree.formHeader(idx);
    if (hdr.head.len == 0) return &.{};
    const head_dup = try a.dupe(u8, hdr.head);
    const out = try a.alloc([]const u8, 1);
    out[0] = head_dup;
    return out;
}

fn childStep(
    a: Allocator,
    tree: *const Ast.Tree,
    child: Ast.NodeIndex,
    siblings: []const Ast.NodeIndex,
    sibling_idx: usize,
) Allocator.Error![]const u8 {
    return switch (tree.tagOf(child)) {
        .kvpair => try a.dupe(u8, tree.kvpairHeader(child).key),
        .form => sub: {
            const ch_hdr = tree.formHeader(child);
            if (ch_hdr.head.len > 0) break :sub try a.dupe(u8, ch_hdr.head);
            break :sub try indexStep(a, positionalIndex(tree, siblings, sibling_idx));
        },
        else => try indexStep(a, positionalIndex(tree, siblings, sibling_idx)),
    };
}

fn positionalIndex(
    tree: *const Ast.Tree,
    siblings: []const Ast.NodeIndex,
    sibling_idx: usize,
) usize {
    var n: usize = 0;
    for (siblings[0..sibling_idx]) |s| {
        if (tree.tagOf(s) != .kvpair) n += 1;
    }
    return n;
}

fn indexStep(a: Allocator, n: usize) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{d}", .{n});
}

fn extendPath(
    a: Allocator,
    parent: []const []const u8,
    step: []const u8,
) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, parent.len + 1);
    @memcpy(out[0..parent.len], parent);
    out[parent.len] = step;
    return out;
}

fn appendStep(
    a: Allocator,
    path: []const []const u8,
    step: []const u8,
) Allocator.Error![]const []const u8 {
    const dup = try a.dupe(u8, step);
    return extendPath(a, path, dup);
}

fn computeBinaryPathPair(
    a: Allocator,
    base: []const []const u8,
    step: StepKind,
    view_kind: BinaryCursor.NodeKind,
    head: []const u8,
) Allocator.Error!PathPair {
    const has_head = view_kind == .form and head.len > 0;
    return switch (step) {
        .root => sub: {
            if (has_head) {
                const p = try extendPath(a, base, try a.dupe(u8, head));
                break :sub .{ .diag = p, .form = p };
            }
            break :sub .{ .diag = base, .form = base };
        },
        .kvpair_value => sub: {
            if (has_head) {
                const fp = try extendPath(a, base, try a.dupe(u8, head));
                break :sub .{ .diag = base, .form = fp };
            }
            break :sub .{ .diag = base, .form = base };
        },
        .positional => |idx| sub: {
            const step_str: []const u8 = if (has_head)
                try a.dupe(u8, head)
            else
                try indexStep(a, idx);
            const p = try extendPath(a, base, step_str);
            break :sub .{ .diag = p, .form = p };
        },
        .vector_element => .{ .diag = base, .form = base },
    };
}

fn validateFormHead(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    path: []const []const u8,
    options: Options,
    local_registry: ?[]const Plugin.FormSpec,
    local_slot_path: []const []const u8,
    local_hit: ?*const Plugin.FormSpec,
) Allocator.Error!void {
    const hdr = tree.formHeader(idx);
    if (hdr.head.len == 0) return;

    if (hdr.namespace == null) {
        if (local_registry) |reg| {
            if (local_hit) |lf| {
                try validateFormKeys(a, diags, schema, cross_index, tree_scope, scope_chain, lf.*, tree, idx, hdr, path, options);
                return;
            }
            switch (schema.lookupForm(hdr.head, null)) {
                .found => |hit| {
                    try validateFormKeys(a, diags, schema, cross_index, tree_scope, scope_chain, hit.form.*, tree, idx, hdr, path, options);
                    return;
                },
                .ambiguous => |amb| {
                    try emitAmbiguous(a, diags, hdr.head_span, path, "form", hdr.head, amb.slice());
                    return;
                },
                .not_found => {
                    try emitUnknownLocalForm(a, diags, hdr.head_span, local_slot_path, hdr.head, reg);
                    return;
                },
            }
        }
    }

    const form_hit = schema.lookupForm(hdr.head, hdr.namespace);
    switch (form_hit) {
        .found => |hit| {
            try validateFormKeys(a, diags, schema, cross_index, tree_scope, scope_chain, hit.form.*, tree, idx, hdr, path, options);
            return;
        },
        .ambiguous => |amb| {
            try emitAmbiguous(a, diags, hdr.head_span, path, "form", hdr.head, amb.slice());
            return;
        },
        .not_found => {},
    }

    const expr_hit = schema.lookupExprFunc(hdr.head, hdr.namespace);
    switch (expr_hit) {
        .found => |hit| {
            const resolved = try Schema.resolveExprArgs(a, hit.func.*, tree, hdr);
            switch (resolved) {
                .err => |re| {
                    try emitResolveError(a, diags, path, hit.func.*, hdr, re);
                    return;
                },
                .ok => |r| {
                    if (!hit.func.checkArity(r.positional.len)) {
                        try emitArity(a, diags, hdr.head_span, path, hit.func.*, r.positional.len);
                    }
                    if (r.signature) |sig| {
                        for (r.positional, 0..) |ch, i| {
                            const ctag = tree.tagOf(ch);
                            if (ctag == .symbol) continue;
                            if (sig.paramType(i)) |t| {
                                if (try matchValueAgainstType(a, schema, cross_index, tree_scope, scope_chain, tree, ch, t, 0)) |fail| {
                                    const arg_step = try indexStep(a, i);
                                    const arg_path = try extendPath(a, path, arg_step);
                                    try emitTypeMismatch(
                                        a,
                                        diags,
                                        tree,
                                        ch,
                                        arg_path,
                                        hit.func.name,
                                        .{ .expr_arg = @intCast(i) },
                                        t,
                                        fail,
                                    );
                                }
                            }
                        }
                        return;
                    }
                    const overloaded = hit.func.signatures != null;
                    var cand_mask: u32 = if (overloaded)
                        overloadInitialMask(hit.func.*, hdr.children.len)
                    else
                        0;
                    for (hdr.children, 0..) |ch, positional_idx| {
                        const ctag = tree.tagOf(ch);
                        const checkable_overload = ctag != .symbol and ctag != .form;
                        const checkable_mono = ctag != .symbol;
                        if (checkable_overload and overloaded) {
                            const ckind = ctag.toValueKind();
                            const accept = overloadAcceptMask(hit.func.*, positional_idx, ckind);
                            const new_mask = cand_mask & accept;
                            if (cand_mask != 0 and new_mask == 0) {
                                const arg_step = try indexStep(a, positional_idx);
                                const arg_path = try extendPath(a, path, arg_step);
                                try emitOverloadMismatch(
                                    a,
                                    diags,
                                    tree.spanOf(ch),
                                    arg_path,
                                    hit.func.*,
                                    positional_idx,
                                    cand_mask,
                                    ckind,
                                );
                            }
                            cand_mask = new_mask;
                        } else if (checkable_mono and !overloaded) {
                            if (hit.func.paramType(positional_idx)) |t| {
                                if (try matchValueAgainstType(a, schema, cross_index, tree_scope, scope_chain, tree, ch, t, 0)) |fail| {
                                    const arg_step = try indexStep(a, positional_idx);
                                    const arg_path = try extendPath(a, path, arg_step);
                                    try emitTypeMismatch(
                                        a,
                                        diags,
                                        tree,
                                        ch,
                                        arg_path,
                                        hit.func.name,
                                        .{ .expr_arg = @intCast(positional_idx) },
                                        t,
                                        fail,
                                    );
                                }
                            }
                        }
                    }
                    return;
                },
            }
        },
        .ambiguous => |amb| {
            try emitAmbiguous(a, diags, hdr.head_span, path, "expression", hdr.head, amb.slice());
            return;
        },
        .not_found => {},
    }

    try emitUnknown(a, diags, hdr.head_span, path, hdr.head, hdr.namespace);
}

const FormKeysState = struct {
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    spec: Plugin.FormSpec,
    tree: *const Ast.Tree,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    path: []const []const u8,
    options: Options,

    any_required: bool,
    seen: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
    seen_variant: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
    resolved_when: ?[]const u8 = null,
    resolved_variant_idx: ?usize = null,
    discriminant_via_overlay: bool = false,
    overlay_present: ?std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS) = null,
    overlay_present_variant: ?std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS) = null,
};

fn validateFormKeys(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    spec: Plugin.FormSpec,
    tree: *const Ast.Tree,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    path: []const []const u8,
    options: Options,
) Allocator.Error!void {
    std.debug.assert(spec.keys.len <= Plugin.MAX_FORM_KEYS);

    var any_required = false;
    for (spec.keys) |k| {
        if (!k.effectiveOptional()) {
            any_required = true;
            break;
        }
    }

    var st: FormKeysState = .{
        .a = a,
        .diags = diags,
        .schema = schema,
        .cross_index = cross_index,
        .tree_scope = tree_scope,
        .scope_chain = scope_chain,
        .spec = spec,
        .tree = tree,
        .form_idx = form_idx,
        .hdr = hdr,
        .path = path,
        .options = options,
        .any_required = any_required,
        .seen = .initEmpty(),
        .seen_variant = .initEmpty(),
    };

    try emitDuplicateKvpairKeys(&st);
    try preresolveDiscriminantViaOverlay(&st);
    try validateChildKvpairsAndPositionals(&st);

    if (spec.open) return;

    try emitMissingDiscriminant(&st);
    computeOverlayPresenceBitsets(&st);
    try emitMissingRequiredTopLevel(&st);
    try emitExclusiveGroupDiagnosticsTree(
        st.a,
        st.diags,
        st.spec.exclusive_groups,
        st.spec.keys,
        st.seen,
        st.overlay_present,
        st.spec.name,
        null,
        st.hdr.head_span,
        st.path,
    );
    try emitVariantSweeps(&st);
    try runEffectiveRefLookups(&st);
}

fn emitDuplicateKvpairKeys(st: *FormKeysState) Allocator.Error!void {
    for (st.hdr.children, 0..) |ch, idx| {
        if (st.tree.tagOf(ch) != .kvpair) continue;
        const kvh = st.tree.kvpairHeader(ch);
        for (st.hdr.children[0..idx]) |prior| {
            if (st.tree.tagOf(prior) != .kvpair) continue;
            if (std.mem.eql(u8, st.tree.kvpairHeader(prior).key, kvh.key)) {
                const dup_path = try appendStep(st.a, st.path, kvh.key);
                try emit(st.a, st.diags, kvh.key_span, dup_path, .err, .duplicate_key, try std.fmt.allocPrint(
                    st.a,
                    "duplicate keyword `:{s}` in form `{s}`",
                    .{ kvh.key, st.spec.name },
                ));
                break;
            }
        }
    }
}

fn preresolveDiscriminantViaOverlay(st: *FormKeysState) Allocator.Error!void {
    if (!st.options.axes.variant) return;
    const overlay = st.options.overlay orelse return;
    const didx = st.spec.discriminant_idx orelse return;
    const dkey = st.spec.keys[didx];
    if (authorWroteKvpair(st.tree, st.hdr, dkey.name)) return;
    const entry = overlay.defaultFor(st.form_idx, dkey.name) orelse return;
    const stext: []const u8 = switch (entry.value) {
        .keyword => |k| k,
        .string => |s| s,
        else => return,
    };
    const vs = st.spec.variants orelse &.{};
    for (vs, 0..) |v, vi| {
        if (std.mem.eql(u8, v.when, stext)) {
            st.resolved_when = v.when;
            st.resolved_variant_idx = vi;
            st.discriminant_via_overlay = true;
            return;
        }
    }
}

fn validateChildKvpairsAndPositionals(st: *FormKeysState) Allocator.Error!void {
    var positional_n: usize = 0;
    for (st.hdr.children) |ch| {
        if (st.tree.tagOf(ch) == .kvpair) {
            const kvh = st.tree.kvpairHeader(ch);
            const found_declared = try matchAndTypecheckDeclaredKey(st, kvh);
            const found_variant = if (!found_declared)
                try matchAndTypecheckVariantKey(st, kvh)
            else
                false;
            if (!found_declared and !found_variant and !st.spec.open) {
                try emitUnknownKeywordKvpair(st, kvh);
            }
        } else {
            try validatePositionalChild(st, ch, positional_n);
            positional_n += 1;
        }
    }
}

fn matchAndTypecheckDeclaredKey(
    st: *FormKeysState,
    kvh: Ast.KvPairHeader,
) Allocator.Error!bool {
    for (st.spec.keys, 0..) |k, ki| {
        if (!std.mem.eql(u8, k.name, kvh.key)) continue;
        if (ki < Plugin.MAX_FORM_KEYS) st.seen.set(ki);
        if (try matchValueAgainstType(st.a, st.schema, st.cross_index, st.tree_scope, st.scope_chain, st.tree, kvh.value, k.value_type, 0)) |fail| {
            const value_path = try appendStep(st.a, st.path, kvh.key);
            try emitTypeMismatch(
                st.a,
                st.diags,
                st.tree,
                kvh.value,
                value_path,
                st.spec.name,
                .{ .key = k.name },
                k.value_type,
                fail,
            );
        } else {
            const value_path = try appendStep(st.a, st.path, kvh.key);
            try emitDeprecatedMemberTree(st.a, st.diags, st.schema, st.tree, kvh.value, k.value_type, value_path);
            try emitStringPatternUnsupportedTree(st.a, st.diags, st.schema, st.tree, kvh.value, k.value_type, value_path);
        }
        if (st.spec.discriminant_idx) |didx| {
            if (ki == didx and st.tree.tagOf(kvh.value) == .symbol) {
                const sym = st.tree.symbolText(kvh.value);
                const vs = st.spec.variants orelse &.{};
                for (vs, 0..) |v, vi| {
                    if (std.mem.eql(u8, v.when, sym)) {
                        st.resolved_when = v.when;
                        st.resolved_variant_idx = vi;
                        break;
                    }
                }
            }
        }
        return true;
    }
    return false;
}

fn matchAndTypecheckVariantKey(
    st: *FormKeysState,
    kvh: Ast.KvPairHeader,
) Allocator.Error!bool {
    const vi = st.resolved_variant_idx orelse return false;
    const vs = st.spec.variants.?;
    const v = vs[vi];
    for (v.keys, 0..) |vk, vki| {
        if (!std.mem.eql(u8, vk.name, kvh.key)) continue;
        if (vki < Plugin.MAX_FORM_KEYS) st.seen_variant.set(vki);
        if (try matchValueAgainstType(st.a, st.schema, st.cross_index, st.tree_scope, st.scope_chain, st.tree, kvh.value, vk.value_type, 0)) |fail| {
            const value_path = try appendStep(st.a, st.path, kvh.key);
            try emitTypeMismatch(
                st.a,
                st.diags,
                st.tree,
                kvh.value,
                value_path,
                st.spec.name,
                .{ .key = vk.name },
                vk.value_type,
                fail,
            );
        } else {
            const value_path = try appendStep(st.a, st.path, kvh.key);
            try emitDeprecatedMemberTree(st.a, st.diags, st.schema, st.tree, kvh.value, vk.value_type, value_path);
            try emitStringPatternUnsupportedTree(st.a, st.diags, st.schema, st.tree, kvh.value, vk.value_type, value_path);
        }
        return true;
    }
    return false;
}

fn emitUnknownKeywordKvpair(
    st: *FormKeysState,
    kvh: Ast.KvPairHeader,
) Allocator.Error!void {
    const unk_path = try appendStep(st.a, st.path, kvh.key);
    if (st.spec.discriminant_idx != null and st.resolved_when == null) {
        const dname = st.spec.discriminant_name orelse "kind";
        try emit(st.a, st.diags, kvh.key_span, unk_path, .err, .unknown_key, try std.fmt.allocPrint(
            st.a,
            "unknown keyword `:{s}` in form `{s}` — `:{s}` must be set before variant-only keys",
            .{ kvh.key, st.spec.name, dname },
        ));
        return;
    }
    var msg_buf: std.ArrayList(u8) = .empty;
    try msg_buf.appendSlice(st.a, "unknown keyword `:");
    try msg_buf.appendSlice(st.a, kvh.key);
    try msg_buf.appendSlice(st.a, "` in form `");
    try msg_buf.appendSlice(st.a, st.spec.name);
    try msg_buf.appendSlice(st.a, "`");
    if (st.resolved_when) |w| {
        try msg_buf.appendSlice(st.a, " (variant `:when ");
        try msg_buf.appendSlice(st.a, w);
        try msg_buf.appendSlice(st.a, "`)");
    }
    try emit(st.a, st.diags, kvh.key_span, unk_path, .err, .unknown_key, try msg_buf.toOwnedSlice(st.a));
}

fn validatePositionalChild(
    st: *FormKeysState,
    ch: Ast.NodeIndex,
    positional_n: usize,
) Allocator.Error!void {
    const pos_step = try positionalStep(st.a, st.tree, ch, positional_n);
    const pos_path = try extendPath(st.a, st.path, pos_step);
    switch (st.spec.positional) {
        .none => if (!st.spec.open) try emit(st.a, st.diags, st.tree.spanOf(ch), pos_path, .err, .positional_not_allowed, try std.fmt.allocPrint(
            st.a,
            "form `{s}` does not accept positional children",
            .{st.spec.name},
        )),
        .any => {},
        .kind => |kind_ref| {
            const expected: Plugin.ValueType = .{ .named = kind_ref };
            if (try matchValueAgainstType(st.a, st.schema, st.cross_index, st.tree_scope, st.scope_chain, st.tree, ch, expected, 0)) |fail| {
                try emitTypeMismatch(
                    st.a,
                    st.diags,
                    st.tree,
                    ch,
                    pos_path,
                    st.spec.name,
                    .positional,
                    expected,
                    fail,
                );
            } else {
                try emitStringPatternUnsupportedTree(st.a, st.diags, st.schema, st.tree, ch, expected, pos_path);
            }
        },
        .flag_set => |fs| {
            const is_kw = st.tree.tagOf(ch) == .keyword;
            const got: []const u8 = if (is_kw) st.tree.keywordText(ch) else "";
            switch (classifyFlag(is_kw, got, fs.flags)) {
                .ok => if (priorFlagText(st.tree, st.hdr.children, ch, got))
                    try emit(st.a, st.diags, st.tree.spanOf(ch), pos_path, .err, .duplicate_positional_flag, try flagDuplicateMsg(st.a, st.spec.name, got)),
                .wrong_shape => try emit(st.a, st.diags, st.tree.spanOf(ch), pos_path, .err, .wrong_underlying, try flagWrongShapeMsg(st.a, st.spec.name)),
                .not_member => try emit(st.a, st.diags, st.tree.spanOf(ch), pos_path, .err, .not_flag_member, try flagNotMemberMsg(st.a, st.spec.name, got, fs.flags)),
            }
        },
    }
}

const FlagClass = enum { ok, wrong_shape, not_member };

fn classifyFlag(is_keyword: bool, got: []const u8, flags: []const Plugin.PositionalSpec.FlagSet.Flag) FlagClass {
    if (!is_keyword) return .wrong_shape;
    for (flags) |f| {
        if (std.mem.eql(u8, f.name, got)) return .ok;
    }
    return .not_member;
}

fn flagWrongShapeMsg(a: Allocator, form_name: []const u8) Allocator.Error![]const u8 {
    return try std.fmt.allocPrint(
        a,
        "form `{s}` accepts only positional keyword flags here, not a value",
        .{form_name},
    );
}

fn flagNotMemberMsg(
    a: Allocator,
    form_name: []const u8,
    got: []const u8,
    flags: []const Plugin.PositionalSpec.FlagSet.Flag,
) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "positional flag `:");
    try buf.appendSlice(a, got);
    try buf.appendSlice(a, "` is not declared on form `");
    try buf.appendSlice(a, form_name);
    try buf.appendSlice(a, "` (declared flags: ");
    for (flags, 0..) |f, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, ":");
        try buf.appendSlice(a, f.name);
    }
    try buf.appendSlice(a, ")");
    return try buf.toOwnedSlice(a);
}

fn priorFlagText(tree: *const Ast.Tree, children: []const Ast.NodeIndex, cur: Ast.NodeIndex, got: []const u8) bool {
    for (children) |ci| {
        if (ci == cur) return false;
        if (tree.tagOf(ci) != .keyword) continue;
        if (std.mem.eql(u8, tree.keywordText(ci), got)) return true;
    }
    return false;
}

fn flagDuplicateMsg(a: Allocator, form_name: []const u8, got: []const u8) Allocator.Error![]const u8 {
    return try std.fmt.allocPrint(
        a,
        "positional flag `:{s}` is repeated on form `{s}`",
        .{ got, form_name },
    );
}

fn emitMissingDiscriminant(st: *FormKeysState) Allocator.Error!void {
    const didx = st.spec.discriminant_idx orelse return;
    if (didx >= Plugin.MAX_FORM_KEYS) return;
    if (st.seen.isSet(didx)) return;
    if (st.discriminant_via_overlay) return;
    const dname = st.spec.discriminant_name orelse st.spec.keys[didx].name;
    try emit(st.a, st.diags, st.hdr.head_span, st.path, .err, .missing_discriminant_key, try std.fmt.allocPrint(
        st.a,
        "form `{s}` is missing required discriminant `:{s}`",
        .{ st.spec.name, dname },
    ));
}

fn computeOverlayPresenceBitsets(st: *FormKeysState) void {
    if (!st.options.axes.exclusive_group) return;
    const overlay = st.options.overlay orelse return;
    var op = std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS).initEmpty();
    for (st.spec.keys, 0..) |k, ki| {
        if (ki >= Plugin.MAX_FORM_KEYS) break;
        if (st.seen.isSet(ki)) continue;
        if (overlay.defaultFor(st.form_idx, k.name) != null) {
            op.set(ki);
        }
    }
    st.overlay_present = op;
    if (st.resolved_variant_idx) |vi| {
        const vs = st.spec.variants.?;
        var opv = std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS).initEmpty();
        for (vs[vi].keys, 0..) |vk, vki| {
            if (vki >= Plugin.MAX_FORM_KEYS) break;
            if (st.seen_variant.isSet(vki)) continue;
            if (overlay.defaultFor(st.form_idx, vk.name) != null) {
                opv.set(vki);
            }
        }
        st.overlay_present_variant = opv;
    }
}

fn emitMissingRequiredTopLevel(st: *FormKeysState) Allocator.Error!void {
    if (!st.any_required) return;
    for (st.spec.keys, 0..) |k, ki| {
        if (k.effectiveOptional()) continue;
        if (ki < Plugin.MAX_FORM_KEYS and st.seen.isSet(ki)) continue;
        if (st.spec.discriminant_idx) |didx| {
            if (ki == didx) continue;
        }
        if (keyInExclusiveGroup(st.spec.exclusive_groups, k.name)) continue;
        try emit(st.a, st.diags, st.hdr.head_span, st.path, .err, .missing_required_key, try std.fmt.allocPrint(
            st.a,
            "form `{s}` is missing required keyword `:{s}`",
            .{ st.spec.name, k.name },
        ));
    }
}

fn emitVariantSweeps(st: *FormKeysState) Allocator.Error!void {
    const vi = st.resolved_variant_idx orelse return;
    const v = st.spec.variants.?[vi];
    for (v.keys, 0..) |vk, vki| {
        if (vk.effectiveOptional()) continue;
        if (vki < Plugin.MAX_FORM_KEYS and st.seen_variant.isSet(vki)) continue;
        var present = false;
        for (st.hdr.children) |ch2| {
            if (st.tree.tagOf(ch2) != .kvpair) continue;
            if (std.mem.eql(u8, st.tree.kvpairHeader(ch2).key, vk.name)) {
                present = true;
                break;
            }
        }
        if (present) continue;
        if (keyInExclusiveGroup(v.exclusive_groups, vk.name)) continue;
        try emit(st.a, st.diags, st.hdr.head_span, st.path, .err, .missing_required_key, try std.fmt.allocPrint(
            st.a,
            "form `{s}` (variant `:when {s}`) is missing required keyword `:{s}`",
            .{ st.spec.name, v.when, vk.name },
        ));
    }
    try emitExclusiveGroupDiagnosticsTree(
        st.a,
        st.diags,
        v.exclusive_groups,
        v.keys,
        st.seen_variant,
        st.overlay_present_variant,
        st.spec.name,
        v.when,
        st.hdr.head_span,
        st.path,
    );
}

fn runEffectiveRefLookups(st: *FormKeysState) Allocator.Error!void {
    if (!st.options.axes.ref_lookup) return;
    const overlay = st.options.overlay orelse return;
    try checkEffectiveRefLookups(
        st.a,
        st.diags,
        st.schema,
        st.cross_index,
        st.tree_scope,
        st.scope_chain,
        st.spec,
        st.tree,
        st.form_idx,
        st.hdr,
        st.path,
        overlay,
        st.seen,
        st.resolved_variant_idx,
        st.seen_variant,
    );
}

fn authorWroteKvpair(tree: *const Ast.Tree, hdr: Ast.FormHeader, key_name: []const u8) bool {
    for (hdr.children) |ch| {
        if (tree.tagOf(ch) != .kvpair) continue;
        if (std.mem.eql(u8, tree.kvpairHeader(ch).key, key_name)) return true;
    }
    return false;
}

fn checkEffectiveRefLookups(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    spec: Plugin.FormSpec,
    tree: *const Ast.Tree,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    path: []const []const u8,
    overlay: *const MaterializedDefaults.MaterializedDefaults,
    seen: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
    resolved_variant_idx: ?usize,
    seen_variant: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
) Allocator.Error!void {
    for (spec.keys, 0..) |k, ki| {
        if (ki < Plugin.MAX_FORM_KEYS and seen.isSet(ki)) continue;
        try maybeEmitEffectiveRefMiss(
            a,
            diags,
            schema,
            cross_index,
            tree_scope,
            scope_chain,
            spec.name,
            tree,
            form_idx,
            hdr,
            path,
            overlay,
            k,
        );
    }
    if (resolved_variant_idx) |vi| {
        const v = spec.variants.?[vi];
        for (v.keys, 0..) |vk, vki| {
            if (vki < Plugin.MAX_FORM_KEYS and seen_variant.isSet(vki)) continue;
            try maybeEmitEffectiveRefMiss(
                a,
                diags,
                schema,
                cross_index,
                tree_scope,
                scope_chain,
                spec.name,
                tree,
                form_idx,
                hdr,
                path,
                overlay,
                vk,
            );
        }
    }
}

fn maybeEmitEffectiveRefMiss(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    form_name: []const u8,
    tree: *const Ast.Tree,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    path: []const []const u8,
    overlay: *const MaterializedDefaults.MaterializedDefaults,
    key: Plugin.KeySpec,
) Allocator.Error!void {
    _ = tree;
    const named = switch (key.value_type) {
        .named => |n| n,
        else => return,
    };
    const lookup = schema.lookupValueKind(named.name, named.namespace);
    const kind_ptr = switch (lookup) {
        .found => |v| v,
        else => return,
    };
    const cr = kind_ptr.cross_ref orelse return;

    const entry = overlay.defaultFor(form_idx, key.name) orelse return;
    const got = switch (entry.value) {
        .keyword => |k| k,
        .string => |s| s,
        else => return,
    };

    const canonical = (try canonicalCrossRefTarget(a, schema, cr.target_form)) orelse return;
    const lookup_scope: ScopeId = if (cr.scope_form) |sf| sub: {
        const scope_canonical = (try canonicalCrossRefTarget(a, schema, sf)) orelse return;
        break :sub findNearestScope(scope_chain, scope_canonical) orelse return;
    } else tree_scope;

    if (cross_index.contains(lookup_scope, canonical, got)) return;

    var step_path: std.ArrayList([]const u8) = .empty;
    try step_path.appendSlice(a, path);
    try step_path.append(a, try a.dupe(u8, key.name));
    try step_path.append(a, try a.dupe(u8, "default"));
    const default_path = try step_path.toOwnedSlice(a);

    const msg = try std.fmt.allocPrint(
        a,
        "form `{s}` keyword `:{s}` default `{s}` does not name a `({s} …)` instance",
        .{ form_name, key.name, got, canonical },
    );
    try emit(a, diags, hdr.head_span, default_path, .err, .not_cross_ref, msg);
}

fn keyInExclusiveGroup(groups: []const Plugin.ExclusiveGroup, name: []const u8) bool {
    for (groups) |g| {
        for (g.alternatives) |alt| {
            for (alt.keys) |k| {
                if (std.mem.eql(u8, k, name)) return true;
            }
        }
    }
    return false;
}

fn alternativePresentTree(
    alt: Plugin.Alternative,
    keys: []const Plugin.KeySpec,
    seen: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
) bool {
    if (alt.keys.len == 0) return false;
    for (alt.keys) |alt_key| {
        const idx = indexOfKey(keys, alt_key) orelse return false;
        if (idx >= Plugin.MAX_FORM_KEYS) return false;
        if (!seen.isSet(idx)) return false;
    }
    return true;
}

fn alternativePartiallyPresentTree(
    alt: Plugin.Alternative,
    keys: []const Plugin.KeySpec,
    seen: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
) bool {
    if (alt.keys.len <= 1) return false;
    var any_set = false;
    var any_absent = false;
    for (alt.keys) |alt_key| {
        const idx = indexOfKey(keys, alt_key) orelse {
            any_absent = true;
            continue;
        };
        if (idx >= Plugin.MAX_FORM_KEYS) {
            any_absent = true;
            continue;
        }
        if (seen.isSet(idx)) any_set = true else any_absent = true;
    }
    return any_set and any_absent;
}

fn alternativeDefaultResolved(
    alt: Plugin.Alternative,
    keys: []const Plugin.KeySpec,
    seen: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
    overlay_present: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
) bool {
    if (alt.keys.len == 0) return false;
    var saw_default = false;
    for (alt.keys) |alt_key| {
        const idx = indexOfKey(keys, alt_key) orelse return false;
        if (idx >= Plugin.MAX_FORM_KEYS) return false;
        const in_seen = seen.isSet(idx);
        const in_overlay = overlay_present.isSet(idx);
        if (!in_seen and !in_overlay) return false;
        if (!in_seen and in_overlay) saw_default = true;
    }
    return saw_default;
}

fn indexOfKey(keys: []const Plugin.KeySpec, name: []const u8) ?usize {
    for (keys, 0..) |k, i| {
        if (std.mem.eql(u8, k.name, name)) return i;
    }
    return null;
}

fn emitExclusiveGroupDiagnosticsTree(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    groups: []const Plugin.ExclusiveGroup,
    keys: []const Plugin.KeySpec,
    seen: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
    overlay_present: ?std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
    form_name: []const u8,
    variant_when: ?[]const u8,
    span: Ast.Span,
    path: []const []const u8,
) Allocator.Error!void {
    for (groups) |group| {
        var author_count: usize = 0;
        for (group.alternatives) |alt| {
            if (alternativePresentTree(alt, keys, seen)) author_count += 1;
        }
        var default_count: usize = 0;
        if (author_count == 0) {
            if (overlay_present) |op| {
                for (group.alternatives) |alt| {
                    if (alternativeDefaultResolved(alt, keys, seen, op)) default_count += 1;
                }
            }
        }

        if (author_count >= 2) {
            try emit(a, diags, span, path, .err, .mutually_exclusive_keys_present, try formatExclusiveMessage(
                a,
                form_name,
                variant_when,
                group,
                .mutually_exclusive_keys_present,
            ));
            continue;
        }

        if (author_count == 0) {
            for (group.alternatives) |alt| {
                if (alternativePartiallyPresentTree(alt, keys, seen)) {
                    try emit(a, diags, span, path, .err, .exclusive_bundle_partial, try formatExclusiveBundleMessage(
                        a,
                        form_name,
                        variant_when,
                        alt,
                        keys,
                        seen,
                    ));
                }
            }
        }

        if (author_count == 0 and default_count > 1) {
            try emit(a, diags, span, path, .err, .multiple_defaulted_alternatives_in_group, try formatExclusiveMessage(
                a,
                form_name,
                variant_when,
                group,
                .multiple_defaulted_alternatives_in_group,
            ));
            continue;
        }

        const present_count = author_count + default_count;
        if (present_count == 0 and group.cardinality == .exactly_one) {
            var partial_seen = false;
            for (group.alternatives) |alt| {
                if (alternativePartiallyPresentTree(alt, keys, seen)) {
                    partial_seen = true;
                    break;
                }
            }
            if (!partial_seen) {
                try emit(a, diags, span, path, .err, .required_one_of_missing, try formatExclusiveMessage(
                    a,
                    form_name,
                    variant_when,
                    group,
                    .required_one_of_missing,
                ));
            }
        }
    }
}

fn formatExclusiveMessage(
    a: Allocator,
    form_name: []const u8,
    variant_when: ?[]const u8,
    group: Plugin.ExclusiveGroup,
    code: Diagnostic.Code,
) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "form `");
    try buf.appendSlice(a, form_name);
    try buf.appendSlice(a, "`");
    if (variant_when) |w| {
        try buf.appendSlice(a, " (variant `:when ");
        try buf.appendSlice(a, w);
        try buf.appendSlice(a, "`)");
    }
    switch (code) {
        .mutually_exclusive_keys_present => try buf.appendSlice(a, ": at most one of "),
        .required_one_of_missing => try buf.appendSlice(a, ": exactly one of "),
        .multiple_defaulted_alternatives_in_group => try buf.appendSlice(a, ": schema admits more than one default-only path through "),
        else => try buf.appendSlice(a, ": "),
    }
    for (group.alternatives, 0..) |alt, ai| {
        if (ai > 0) try buf.appendSlice(a, " | ");
        for (alt.keys, 0..) |kn, ki| {
            if (ki > 0) try buf.appendSlice(a, "+");
            try buf.appendSlice(a, ":");
            try buf.appendSlice(a, kn);
        }
    }
    switch (code) {
        .mutually_exclusive_keys_present => try buf.appendSlice(a, " may be present"),
        .required_one_of_missing => try buf.appendSlice(a, " must be present"),
        .multiple_defaulted_alternatives_in_group => try buf.appendSlice(a, " — author has no kvpair to disambiguate"),
        else => {},
    }
    return try buf.toOwnedSlice(a);
}

fn formatExclusiveBundleMessage(
    a: Allocator,
    form_name: []const u8,
    variant_when: ?[]const u8,
    alt: Plugin.Alternative,
    keys: []const Plugin.KeySpec,
    seen: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "form `");
    try buf.appendSlice(a, form_name);
    try buf.appendSlice(a, "`");
    if (variant_when) |w| {
        try buf.appendSlice(a, " (variant `:when ");
        try buf.appendSlice(a, w);
        try buf.appendSlice(a, "`)");
    }
    try buf.appendSlice(a, ": exclusive-group alt `");
    for (alt.keys, 0..) |kn, ki| {
        if (ki > 0) try buf.appendSlice(a, "+");
        try buf.appendSlice(a, ":");
        try buf.appendSlice(a, kn);
    }
    try buf.appendSlice(a, "` is partially present (");
    var first = true;
    for (alt.keys) |kn| {
        if (!first) try buf.appendSlice(a, ", ");
        first = false;
        try buf.appendSlice(a, ":");
        try buf.appendSlice(a, kn);
        const idx = indexOfKey(keys, kn);
        const is_set = if (idx) |i| (i < Plugin.MAX_FORM_KEYS and seen.isSet(i)) else false;
        try buf.appendSlice(a, if (is_set) " set" else " missing");
    }
    try buf.appendSlice(a, "); bundles are all-or-nothing");
    return try buf.toOwnedSlice(a);
}

fn positionalStep(
    a: Allocator,
    tree: *const Ast.Tree,
    child: Ast.NodeIndex,
    n: usize,
) Allocator.Error![]const u8 {
    if (tree.tagOf(child) == .form) {
        const ch_hdr = tree.formHeader(child);
        if (ch_hdr.head.len > 0) return try a.dupe(u8, ch_hdr.head);
    }
    return indexStep(a, n);
}

comptime {
    std.debug.assert(Plugin.MAX_FORM_KEYS <= @bitSizeOf(u64));
}

fn emit(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    span: Ast.Span,
    path: []const []const u8,
    severity: Severity,
    code: Diagnostic.Code,
    message: []const u8,
) Allocator.Error!void {
    try diags.append(a, .{
        .span = span,
        .severity = severity,
        .code = code,
        .message = message,
        .path = try clonePath(a, path),
    });
}

fn clonePath(a: Allocator, path: []const []const u8) Allocator.Error![]const []const u8 {
    if (path.len == 0) return &.{};
    const out = try a.alloc([]const u8, path.len);
    for (path, 0..) |s, i| out[i] = s;
    return out;
}

fn emitUnknown(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    span: Ast.Span,
    path: []const []const u8,
    head: []const u8,
    namespace: ?[]const u8,
) Allocator.Error!void {
    const msg = if (namespace) |ns|
        try std.fmt.allocPrint(a, "unknown form `{s}/{s}`", .{ ns, head })
    else
        try std.fmt.allocPrint(a, "unknown form `{s}`", .{head});
    try emit(a, diags, span, path, .err, .unknown_form, msg);
}

fn emitUnknownLocalForm(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    span: Ast.Span,
    slot_path: []const []const u8,
    head: []const u8,
    registry: []const Plugin.FormSpec,
) Allocator.Error!void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "unknown form `");
    try buf.appendSlice(a, head);
    try buf.appendSlice(a, "` in this slot — expected one of [");
    for (registry, 0..) |lf, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, lf.name);
    }
    try buf.appendSlice(a, "] or a known form");
    try emit(a, diags, span, slot_path, .err, .unknown_local_form, try buf.toOwnedSlice(a));
}

fn emitAmbiguous(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    span: Ast.Span,
    path: []const []const u8,
    kind: []const u8,
    head: []const u8,
    claimants: []const *const Plugin.Plugin,
) Allocator.Error!void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, kind);
    try buf.appendSlice(a, " `");
    try buf.appendSlice(a, head);
    try buf.appendSlice(a, "` is ambiguous — defined by [");
    for (claimants, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, p.name);
    }
    try buf.appendSlice(a, "]; qualify with `<ns>/");
    try buf.appendSlice(a, head);
    try buf.appendSlice(a, "`");
    const code: Diagnostic.Code =
        if (std.mem.eql(u8, kind, "expression")) .ambiguous_expr else if (std.mem.eql(u8, kind, "value-kind")) .ambiguous_element_kind else .ambiguous_form;
    try emit(a, diags, span, path, .err, code, try buf.toOwnedSlice(a));
}

fn emitResolveError(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    path: []const []const u8,
    func: Plugin.ExprFunc,
    hdr: Ast.FormHeader,
    err: Schema.ResolveError,
) Allocator.Error!void {
    switch (err) {
        .mixed => |m| {
            const msg = try std.fmt.allocPrint(
                a,
                "expression `{s}` mixes positional and labeled arguments — pick one calling style",
                .{func.name},
            );
            try emit(a, diags, m.span, path, .err, .expr_mixed_args, msg);
        },
        .labels_not_supported => |ls| {
            const child_path = try appendStep(a, path, ls.key);
            const msg = try std.fmt.allocPrint(
                a,
                "expression `{s}` does not accept keyword argument `:{s}`",
                .{ func.name, ls.key },
            );
            try emit(a, diags, ls.span, child_path, .err, .expr_kvpair_not_allowed, msg);
        },
        .unknown_label => |ul| {
            const child_path = try appendStep(a, path, ul.key);
            const msg = try std.fmt.allocPrint(
                a,
                "expression `{s}` has no parameter named `{s}`",
                .{ func.name, ul.key },
            );
            try emit(a, diags, ul.span, child_path, .err, .expr_unknown_label, msg);
        },
        .duplicate_label => |dl| {
            const child_path = try appendStep(a, path, dl.key);
            const msg = try std.fmt.allocPrint(
                a,
                "duplicate label `:{s}` in call to `{s}`",
                .{ dl.key, func.name },
            );
            try emit(a, diags, dl.span, child_path, .err, .expr_duplicate_label, msg);
        },
        .missing_label => |ml| {
            const msg = try std.fmt.allocPrint(
                a,
                "expression `{s}` requires labeled argument `:{s}`",
                .{ func.name, ml.name },
            );
            try emit(a, diags, hdr.head_span, path, .err, .expr_missing_label, msg);
        },
    }
}

fn emitArity(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    span: Ast.Span,
    path: []const []const u8,
    func: Plugin.ExprFunc,
    actual: usize,
) Allocator.Error!void {
    const expected = switch (func.arity) {
        .fixed => |k| try std.fmt.allocPrint(a, "exactly {d}", .{k}),
        .at_least => |k| try std.fmt.allocPrint(a, "at least {d}", .{k}),
        .range => |r| try std.fmt.allocPrint(a, "{d}..{d}", .{ r.min, r.max }),
    };
    const msg = try std.fmt.allocPrint(
        a,
        "expression `{s}` expects {s} argument(s), got {d}",
        .{ func.name, expected, actual },
    );
    try emit(a, diags, span, path, .err, .arity_mismatch, msg);
}

fn matchFailToCode(fail: MatchFail) Diagnostic.Code {
    return switch (fail) {
        .wrong_underlying => .wrong_underlying,
        .wrong_vector_len => .vector_length_mismatch,
        .vector_too_short => .vector_too_short,
        .vector_too_long => .vector_too_long,
        .element_at => |e| matchFailToCode(e.fail.*),
        .unit_missing => .unit_required,
        .unit_wrong => .unit_not_allowed,
        .unit_forbidden => .unit_forbidden,
        .not_member => .not_member,
        .not_head_member => .not_head_member,
        .unknown_element_kind => .unknown_element_kind,
        .ambiguous_element_kind => .ambiguous_element_kind,
        .recursion_depth => .recursion_depth,
        .not_cross_ref => .not_cross_ref,
        .cross_ref_outside_scope => .cross_ref_outside_scope,
        .union_no_branch_matched => .union_no_branch_matched,
        .number_below_min => .number_below_min,
        .number_above_max => .number_above_max,
        .number_at_or_below_exclusive_min => .number_at_or_below_exclusive_min,
        .number_at_or_above_exclusive_max => .number_at_or_above_exclusive_max,
        .number_not_integer => .number_not_integer,
        .numeric_bound_unit_mismatch => .numeric_bound_unit_mismatch,
        .repr_out_of_range => .repr_out_of_range,
        .string_too_short => .string_too_short,
        .string_too_long => .string_too_long,
        .string_format_mismatch => .string_format_mismatch,
        .string_pattern_mismatch => .string_pattern_mismatch,
    };
}

const Slot = union(enum) {
    positional,
    key: []const u8,
    expr_arg: u8,
};

const MatchFail = union(enum) {
    wrong_underlying: []const u8,
    wrong_vector_len: struct { want: u16, got: u32 },
    vector_too_short: struct { got: u32, min_len: u16 },
    vector_too_long: struct { got: u32, max_len: u16 },
    element_at: struct {
        index: usize,
        fail: *const MatchFail,
        leaf: Ast.NodeIndex,
    },
    unit_missing: []const []const u8,
    unit_wrong: struct { got: []const u8, allowed: []const []const u8 },
    unit_forbidden: []const u8,
    not_member: struct { got: []const u8, allowed: []const Plugin.ValueKind.MemberSet.Member },
    not_head_member: struct { got: []const u8, allowed: []const []const u8 },
    unknown_element_kind: struct {
        name: []const u8,
        namespace: ?[]const u8 = null,
    },
    ambiguous_element_kind: struct {
        name: []const u8,
        claimants: []const *const Plugin.Plugin,
    },
    recursion_depth,
    not_cross_ref: struct { got: []const u8, target: []const u8 },
    cross_ref_outside_scope: struct { got: []const u8, scope_form: []const u8 },
    union_no_branch_matched: struct {
        got_label: []const u8,
        alternatives: []const Plugin.QualifiedRef,
    },
    number_below_min: NumericFail,
    number_above_max: NumericFail,
    number_at_or_below_exclusive_min: NumericFail,
    number_at_or_above_exclusive_max: NumericFail,
    number_not_integer: f64,
    numeric_bound_unit_mismatch: struct {
        value_unit: ?[]const u8,
        bound_unit: ?[]const u8,
    },
    repr_out_of_range: struct {
        value: f64,
        repr: Plugin.ValueKind.Repr,
        reason: enum { out_of_range, not_integer },
    },

    string_too_short: struct { got: u32, min_len: u32 },
    string_too_long: struct { got: u32, max_len: u32 },
    string_format_mismatch: struct { got: []const u8, format: []const u8 },
    string_pattern_mismatch: struct { got: []const u8, pattern: []const u8 },

    pub const NumericFail = struct {
        value: f64,
        bound: f64,
        unit: ?[]const u8 = null,
    };
};

const NumericValue = union(enum) {
    f: f64,
    i: i64,
    u: u64,

    fn toF64(self: NumericValue) f64 {
        return switch (self) {
            .f => |v| v,
            .i => |v| @floatFromInt(v),
            .u => |v| @floatFromInt(v),
        };
    }

    fn isInteger(self: NumericValue) bool {
        return switch (self) {
            .i, .u => true,
            .f => |v| std.math.isFinite(v) and @floor(v) == v,
        };
    }
};

fn readNumericValueTree(
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    tag: Ast.Tag,
) NumericValue {
    return switch (tag) {
        .number => .{ .f = tree.numberOf(idx) },
        .number_i64 => .{ .i = tree.numberI64Of(idx) },
        .number_u64 => .{ .u = tree.numberU64Of(idx) },
        .number_with_unit => .{ .f = tree.numberWithUnitOf(idx).value },
        else => unreachable,
    };
}

fn boundFitsI64(f: f64) bool {
    return std.math.isFinite(f) and
        @floor(f) == f and
        f >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
        f <= @as(f64, @floatFromInt(std.math.maxInt(i64)));
}

fn boundFitsU64(f: f64) bool {
    return std.math.isFinite(f) and
        @floor(f) == f and
        f >= 0.0 and
        f < 18446744073709551616.0;
}

fn compareToBound(value: NumericValue, bound: Plugin.ValueKind.NumericBounds.Bound) std.math.Order {
    return switch (value) {
        .f => |v| sub: {
            if (std.math.isNan(v) or std.math.isNan(bound.value)) break :sub .eq;
            break :sub std.math.order(v, bound.value);
        },
        .i => |v| sub: {
            if (bound.exact_int and boundFitsI64(bound.value)) {
                const b: i64 = @intFromFloat(bound.value);
                break :sub std.math.order(v, b);
            }
            if (std.math.isNan(bound.value)) break :sub .eq;
            break :sub std.math.order(@as(f64, @floatFromInt(v)), bound.value);
        },
        .u => |v| sub: {
            if (bound.exact_int and boundFitsU64(bound.value)) {
                const b: u64 = @intFromFloat(bound.value);
                break :sub std.math.order(v, b);
            }
            if (std.math.isNan(bound.value)) break :sub .eq;
            break :sub std.math.order(@as(f64, @floatFromInt(v)), bound.value);
        },
    };
}

fn boundUnitMismatch(bound: Plugin.ValueKind.NumericBounds.Bound, value_unit: ?[]const u8) bool {
    if (bound.unit == null) return false;
    if (value_unit == null) return true;
    return !std.mem.eql(u8, bound.unit.?, value_unit.?);
}

fn checkNumericBoundsValue(
    value: NumericValue,
    value_unit: ?[]const u8,
    nb: Plugin.ValueKind.NumericBounds,
) ?MatchFail {
    if (nb.integer and !value.isInteger()) {
        return MatchFail{ .number_not_integer = value.toF64() };
    }
    if (nb.min) |mn| {
        if (boundUnitMismatch(mn, value_unit)) return MatchFail{
            .numeric_bound_unit_mismatch = .{ .value_unit = value_unit, .bound_unit = mn.unit },
        };
        const ord = compareToBound(value, mn);
        if (nb.exclusive_min) {
            if (ord != .gt) return MatchFail{
                .number_at_or_below_exclusive_min = .{ .value = value.toF64(), .bound = mn.value, .unit = mn.unit },
            };
        } else if (ord == .lt) return MatchFail{
            .number_below_min = .{ .value = value.toF64(), .bound = mn.value, .unit = mn.unit },
        };
    }
    if (nb.max) |mx| {
        if (boundUnitMismatch(mx, value_unit)) return MatchFail{
            .numeric_bound_unit_mismatch = .{ .value_unit = value_unit, .bound_unit = mx.unit },
        };
        const ord = compareToBound(value, mx);
        if (nb.exclusive_max) {
            if (ord != .lt) return MatchFail{
                .number_at_or_above_exclusive_max = .{ .value = value.toF64(), .bound = mx.value, .unit = mx.unit },
            };
        } else if (ord == .gt) return MatchFail{
            .number_above_max = .{ .value = value.toF64(), .bound = mx.value, .unit = mx.unit },
        };
    }
    return null;
}

fn checkReprValue(value: NumericValue, repr: Plugin.ValueKind.Repr) ?MatchFail {
    const s = repr.spec();
    if (s.integer and !value.isInteger()) {
        return MatchFail{ .repr_out_of_range = .{ .value = value.toF64(), .repr = repr, .reason = .not_integer } };
    }
    const v = value.toF64();
    if (v < s.min or v > s.max) {
        return MatchFail{ .repr_out_of_range = .{ .value = value.toF64(), .repr = repr, .reason = .out_of_range } };
    }
    return null;
}

fn checkStringBoundsValue(
    text: []const u8,
    sb: Plugin.ValueKind.StringBounds,
) ?MatchFail {
    if (sb.min_len != null or sb.max_len != null) {
        const cp: u32 = blk: {
            const counted = std.unicode.utf8CountCodepoints(text) catch break :blk @intCast(text.len);
            break :blk @intCast(counted);
        };
        if (sb.min_len) |mn| if (cp < mn) return MatchFail{
            .string_too_short = .{ .got = cp, .min_len = mn },
        };
        if (sb.max_len) |mx| if (cp > mx) return MatchFail{
            .string_too_long = .{ .got = cp, .max_len = mx },
        };
    }
    if (sb.format) |fmt| {
        if (!StringFormats.check(fmt, text)) return MatchFail{
            .string_format_mismatch = .{ .got = text, .format = @tagName(fmt) },
        };
    }
    return null;
}

fn matchValueAgainstType(
    a: Allocator,
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    expected: Plugin.ValueType,
    depth: u8,
) Allocator.Error!?MatchFail {
    const tag = tree.tagOf(idx);

    if (tag == .form) {
        if (resolveFormHeadKind(schema, expected)) |kind| {
            if (kind.heads) |hs| {
                const head = tree.formHeader(idx).head;
                for (hs.names) |n| if (std.mem.eql(u8, n, head)) return null;
                return MatchFail{ .not_head_member = .{ .got = head, .allowed = hs.names } };
            }
            return null;
        }
        if (isAnyType(expected)) return null;
        const form_or_expr_handled: ?(?MatchFail) = blk: {
            switch (expected) {
                .form => break :blk @as(?MatchFail, null),
                .expr => {
                    const res = try resolveFormExpression(a, schema, tree, idx);
                    break :blk switch (res) {
                        .expr => @as(?MatchFail, null),
                        .data_form => @as(?MatchFail, MatchFail{ .wrong_underlying = typeLabel(expected) }),
                        .unresolved => @as(?MatchFail, null),
                    };
                },
                else => break :blk null,
            }
        };
        if (form_or_expr_handled) |v| return v;
        if (resolvesToUnion(schema, expected)) {} else {
            const res = try resolveFormExpression(a, schema, tree, idx);
            return switch (res) {
                .unresolved => null,
                .data_form => MatchFail{ .wrong_underlying = typeLabel(expected) },
                .expr => |e| sub: {
                    const declared = e.result orelse break :sub null;
                    break :sub switch (declaredResultMatchesExpected(schema, declared, expected)) {
                        .yes, .unknown => null,
                        .no => MatchFail{ .wrong_underlying = typeLabel(expected) },
                    };
                },
            };
        }
    }

    return switch (expected) {
        .any => null,
        .number => switch (tag) {
            .number, .number_with_unit, .number_i64, .number_u64 => null,
            else => MatchFail{ .wrong_underlying = "number" },
        },
        .string => if (tag == .string) null else MatchFail{ .wrong_underlying = "string" },
        .symbol => if (tag == .symbol) null else MatchFail{ .wrong_underlying = "symbol" },
        .boolean => switch (tag) {
            .boolean_true, .boolean_false => null,
            else => MatchFail{ .wrong_underlying = "boolean" },
        },
        .nil => if (tag == .nil) null else MatchFail{ .wrong_underlying = "nil" },
        .vector => if (tag == .vector) null else MatchFail{ .wrong_underlying = "vector" },
        .form, .expr => MatchFail{ .wrong_underlying = "form" },
        .named => |kind_ref| blk: {
            if (resolvePrimitiveShortcut(kind_ref.name)) |vt| {
                break :blk try matchValueAgainstType(a, schema, cross_index, tree_scope, scope_chain, tree, idx, vt, depth);
            }
            const kind = switch (schema.lookupValueKind(kind_ref.name, kind_ref.namespace)) {
                .found => |k| k,
                .not_found => break :blk MatchFail{ .unknown_element_kind = .{
                    .name = kind_ref.name,
                    .namespace = kind_ref.namespace,
                } },
                .ambiguous => |amb| break :blk MatchFail{ .ambiguous_element_kind = .{
                    .name = kind_ref.name,
                    .claimants = try a.dupe(*const Plugin.Plugin, amb.slice()),
                } },
            };
            const next_depth = depth + 1;
            if (next_depth >= Schema.MAX_KIND_DEPTH) break :blk .recursion_depth;
            break :blk try matchValueAgainstKind(a, schema, cross_index, tree_scope, scope_chain, tree, idx, kind, next_depth);
        },
    };
}

fn resolvePrimitiveShortcut(name: []const u8) ?Plugin.ValueType {
    if (std.mem.eql(u8, name, "any")) return .any;
    if (std.mem.eql(u8, name, "number")) return .number;
    if (std.mem.eql(u8, name, "string")) return .string;
    if (std.mem.eql(u8, name, "symbol")) return .symbol;
    if (std.mem.eql(u8, name, "boolean")) return .boolean;
    if (std.mem.eql(u8, name, "nil")) return .nil;
    if (std.mem.eql(u8, name, "vector")) return .vector;
    if (std.mem.eql(u8, name, "form")) return .form;
    return null;
}

fn resolveFormHeadKind(
    schema: Schema.Schema,
    expected: Plugin.ValueType,
) ?*const Plugin.ValueKind {
    var current = expected;
    while (true) {
        switch (current) {
            .named => |ref| {
                if (resolvePrimitiveShortcut(ref.name)) |p| {
                    current = p;
                    continue;
                }
                switch (schema.lookupValueKind(ref.name, ref.namespace)) {
                    .found => |k| return if (k.underlying == .form) k else null,
                    else => return null,
                }
            },
            else => return null,
        }
    }
}

fn matchValueAgainstKind(
    a: Allocator,
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind: *const Plugin.ValueKind,
    depth: u8,
) Allocator.Error!?MatchFail {
    const tag = tree.tagOf(idx);
    return switch (kind.underlying) {
        .number => blk: {
            std.debug.assert(kind.members == null);
            const unit_fail: ?MatchFail = switch (tag) {
                .number, .number_i64, .number_u64 => sub: {
                    if (kind.unit) |u| if (u.required) break :sub @as(?MatchFail, .{ .unit_missing = u.allowed });
                    break :sub @as(?MatchFail, null);
                },
                .number_with_unit => sub: {
                    if (kind.unit) |u| {
                        const got = tree.numberWithUnitOf(idx).unit;
                        if (u.reject) break :sub @as(?MatchFail, .{ .unit_forbidden = got });
                        if (u.allowed.len != 0) {
                            var ok: bool = false;
                            for (u.allowed) |w| if (std.mem.eql(u8, w, got)) {
                                ok = true;
                                break;
                            };
                            if (!ok) break :sub @as(?MatchFail, .{ .unit_wrong = .{ .got = got, .allowed = u.allowed } });
                        }
                    }
                    break :sub @as(?MatchFail, null);
                },
                else => break :blk MatchFail{ .wrong_underlying = "number" },
            };
            if (unit_fail) |f| break :blk f;
            if (kind.numeric) |nb| {
                const value = readNumericValueTree(tree, idx, tag);
                const value_unit: ?[]const u8 = if (tag == .number_with_unit)
                    tree.numberWithUnitOf(idx).unit
                else
                    null;
                if (checkNumericBoundsValue(value, value_unit, nb)) |f| break :blk f;
            }
            if (kind.repr) |r| {
                const value = readNumericValueTree(tree, idx, tag);
                if (checkReprValue(value, r)) |f| break :blk f;
            }
            break :blk null;
        },
        .string => blk: {
            if (tag != .string) break :blk MatchFail{ .wrong_underlying = "string" };
            if (kind.members) |m| {
                if (m.members.len != 0) {
                    const got = tree.stringText(idx);
                    var matched: bool = false;
                    for (m.members) |v| if (std.mem.eql(u8, v.name, got)) {
                        matched = true;
                        break;
                    };
                    if (!matched) break :blk MatchFail{ .not_member = .{ .got = got, .allowed = m.members } };
                }
            }
            if (kind.string_bounds) |sb| {
                const text = tree.stringText(idx);
                if (checkStringBoundsValue(text, sb)) |f| break :blk f;
            }
            break :blk null;
        },
        .symbol => blk: {
            if (tag != .symbol) break :blk MatchFail{ .wrong_underlying = "symbol" };
            if (kind.cross_ref) |cr| {
                const got = tree.symbolText(idx);
                const canonical = (try canonicalCrossRefTarget(a, schema, cr.target_form)) orelse {
                    break :blk MatchFail{ .not_cross_ref = .{ .got = got, .target = cr.target_form } };
                };
                const lookup_scope: ScopeId = if (cr.scope_form) |sf| sub: {
                    const scope_canonical = (try canonicalCrossRefTarget(a, schema, sf)) orelse {
                        break :blk MatchFail{ .not_cross_ref = .{ .got = got, .target = canonical } };
                    };
                    break :sub findNearestScope(scope_chain, scope_canonical) orelse {
                        break :blk MatchFail{ .cross_ref_outside_scope = .{ .got = got, .scope_form = scope_canonical } };
                    };
                } else tree_scope;
                const ref_span = tree.spanOf(idx);
                try cross_index.appendReference(lookup_scope, canonical, got, .{
                    .tree_idx = tree_scope.treeIdx(),
                    .node_idx = idx,
                    .form_span = ref_span,
                    .name_span = ref_span,
                    .scope = lookup_scope,
                });
                if (cross_index.contains(lookup_scope, canonical, got)) break :blk null;
                break :blk MatchFail{ .not_cross_ref = .{ .got = got, .target = canonical } };
            }
            if (kind.members) |m| {
                if (m.members.len == 0) break :blk null;
                const got = tree.symbolText(idx);
                for (m.members) |v| if (std.mem.eql(u8, v.name, got)) break :blk null;
                break :blk MatchFail{ .not_member = .{ .got = got, .allowed = m.members } };
            }
            break :blk null;
        },
        .form => blk: {
            std.debug.assert(kind.members == null);
            if (tag != .form) break :blk MatchFail{ .wrong_underlying = "form" };
            if (kind.heads) |hs| {
                const head = tree.formHeader(idx).head;
                for (hs.names) |n| if (std.mem.eql(u8, n, head)) break :blk null;
                break :blk MatchFail{ .not_head_member = .{ .got = head, .allowed = hs.names } };
            }
            break :blk null;
        },
        .vector => blk: {
            std.debug.assert(kind.members == null);
            if (tag != .vector) break :blk MatchFail{ .wrong_underlying = "vector" };
            if (kind.vector) |vs| {
                const elements = tree.vectorElements(idx);
                if (vs.len) |want| {
                    if (elements.len != want) break :blk MatchFail{
                        .wrong_vector_len = .{ .want = want, .got = @intCast(elements.len) },
                    };
                }
                if (vs.min_len) |mn| {
                    if (elements.len < mn) break :blk MatchFail{
                        .vector_too_short = .{ .got = @intCast(elements.len), .min_len = mn },
                    };
                }
                if (vs.max_len) |mx| {
                    if (elements.len > mx) break :blk MatchFail{
                        .vector_too_long = .{ .got = @intCast(elements.len), .max_len = mx },
                    };
                }
                const elem_type: Plugin.ValueType = .{ .named = vs.element };
                for (elements, 0..) |el_idx, i| {
                    const inner = try matchValueAgainstType(a, schema, cross_index, tree_scope, scope_chain, tree, el_idx, elem_type, depth);
                    if (inner) |f| {
                        const owned = try a.create(MatchFail);
                        owned.* = f;
                        break :blk MatchFail{ .element_at = .{ .index = i, .fail = owned, .leaf = el_idx } };
                    }
                }
            }
            break :blk null;
        },
        .union_of => blk: {
            const us = kind.union_of orelse break :blk MatchFail{ .wrong_underlying = "union" };
            for (us.alternatives) |alt_name| {
                const alt_type: Plugin.ValueType = .{ .named = alt_name };
                const inner = try matchValueAgainstType(a, schema, cross_index, tree_scope, scope_chain, tree, idx, alt_type, depth);
                if (inner == null) break :blk null;
            }
            break :blk MatchFail{ .union_no_branch_matched = .{
                .got_label = nodeTagLabel(tag),
                .alternatives = us.alternatives,
            } };
        },
    };
}

fn nodeTagLabel(tag: Ast.Tag) []const u8 {
    return switch (tag) {
        .number, .number_with_unit, .number_i64, .number_u64 => "number",
        .string => "string",
        .keyword => "keyword",
        .symbol => "symbol",
        .boolean_true, .boolean_false => "boolean",
        .nil => "nil",
        .date => "date",
        .time => "time",
        .vector => "vector",
        .form => "form",
        .kvpair => "keyword pair",
    };
}

fn emitTypeMismatch(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    tree: *const Ast.Tree,
    value_idx: Ast.NodeIndex,
    path: []const []const u8,
    form_name: []const u8,
    slot: Slot,
    expected: Plugin.ValueType,
    fail: MatchFail,
) Allocator.Error!void {
    var buf: std.ArrayList(u8) = .empty;
    const noun: []const u8 = switch (slot) {
        .positional, .key => "form",
        .expr_arg => "expression",
    };
    try buf.appendSlice(a, noun);
    try buf.appendSlice(a, " `");
    try buf.appendSlice(a, form_name);
    try buf.appendSlice(a, "` ");
    switch (slot) {
        .positional => try buf.appendSlice(a, "positional argument"),
        .key => |k| {
            try buf.appendSlice(a, "keyword `:");
            try buf.appendSlice(a, k);
            try buf.appendSlice(a, "`");
        },
        .expr_arg => |i| {
            try buf.appendSlice(a, "argument ");
            const piece = try std.fmt.allocPrint(a, "{d}", .{i});
            try buf.appendSlice(a, piece);
        },
    }
    try buf.appendSlice(a, " expects ");
    try describeType(a, &buf, expected);
    try buf.appendSlice(a, ", ");
    try describeFail(a, &buf, tree, value_idx, fail);
    const code: Diagnostic.Code = switch (slot) {
        .expr_arg => .expr_type_mismatch,
        .positional, .key => matchFailToCode(fail),
    };
    try emit(a, diags, tree.spanOf(value_idx), path, .err, code, try buf.toOwnedSlice(a));
}

noinline fn describeType(
    a: Allocator,
    buf: *std.ArrayList(u8),
    expected: Plugin.ValueType,
) Allocator.Error!void {
    switch (expected) {
        .any => try buf.appendSlice(a, "any value"),
        .number => try buf.appendSlice(a, "number"),
        .string => try buf.appendSlice(a, "string"),
        .symbol => try buf.appendSlice(a, "symbol"),
        .boolean => try buf.appendSlice(a, "boolean"),
        .nil => try buf.appendSlice(a, "nil"),
        .vector => try buf.appendSlice(a, "vector"),
        .form => try buf.appendSlice(a, "form"),
        .expr => try buf.appendSlice(a, "expression"),
        .named => |n| {
            try buf.appendSlice(a, "`");
            if (n.namespace) |ns| {
                try buf.appendSlice(a, ns);
                try buf.appendSlice(a, "/");
            }
            try buf.appendSlice(a, n.name);
            try buf.appendSlice(a, "`");
        },
    }
}

fn describeNode(
    a: Allocator,
    buf: *std.ArrayList(u8),
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Allocator.Error!void {
    switch (tree.tagOf(idx)) {
        .number, .number_i64, .number_u64 => try buf.appendSlice(a, "number"),
        .number_with_unit => {
            const nu = tree.numberWithUnitOf(idx);
            try buf.appendSlice(a, "number with unit `");
            try buf.appendSlice(a, nu.unit);
            try buf.appendSlice(a, "`");
        },
        .string => try buf.appendSlice(a, "string"),
        .keyword => try buf.appendSlice(a, "keyword"),
        .symbol => try buf.appendSlice(a, "symbol"),
        .boolean_true, .boolean_false => try buf.appendSlice(a, "boolean"),
        .nil => try buf.appendSlice(a, "nil"),
        .date => try buf.appendSlice(a, "date"),
        .time => try buf.appendSlice(a, "time"),
        .vector => {
            const elems = tree.vectorElements(idx);
            const piece = try std.fmt.allocPrint(a, "vector of length {d}", .{elems.len});
            try buf.appendSlice(a, piece);
        },
        .form => try buf.appendSlice(a, "form"),
        .kvpair => try buf.appendSlice(a, "keyword pair"),
    }
}

fn describeFail(
    a: Allocator,
    buf: *std.ArrayList(u8),
    tree: *const Ast.Tree,
    leaf: Ast.NodeIndex,
    fail: MatchFail,
) Allocator.Error!void {
    switch (fail) {
        .wrong_underlying => {
            try buf.appendSlice(a, "got ");
            try describeNode(a, buf, tree, leaf);
        },
        .wrong_vector_len => |w| {
            const piece = try std.fmt.allocPrint(a, "got vector of length {d}", .{w.got});
            try buf.appendSlice(a, piece);
        },
        .vector_too_short => |v| {
            const piece = try std.fmt.allocPrint(a, "got vector of length {d}, below :min-len {d}", .{ v.got, v.min_len });
            try buf.appendSlice(a, piece);
        },
        .vector_too_long => |v| {
            const piece = try std.fmt.allocPrint(a, "got vector of length {d}, above :max-len {d}", .{ v.got, v.max_len });
            try buf.appendSlice(a, piece);
        },
        .element_at => |e| {
            const piece = try std.fmt.allocPrint(a, "element [{d}]: ", .{e.index});
            try buf.appendSlice(a, piece);
            try describeFail(a, buf, tree, e.leaf, e.fail.*);
        },
        .unit_missing => |allowed| {
            try buf.appendSlice(a, "got number without unit");
            try writeAllowedList(a, buf, allowed);
        },
        .unit_wrong => |w| {
            try buf.appendSlice(a, "got number with unit `");
            try buf.appendSlice(a, w.got);
            try buf.appendSlice(a, "`");
            try writeAllowedList(a, buf, w.allowed);
        },
        .unit_forbidden => |got| {
            try buf.appendSlice(a, "got number with unit `");
            try buf.appendSlice(a, got);
            try buf.appendSlice(a, "` (slot rejects units — bare number required)");
        },
        .not_member => |w| {
            try buf.appendSlice(a, "got `");
            try buf.appendSlice(a, w.got);
            try buf.appendSlice(a, "`");
            try writeAllowedMembers(a, buf, w.allowed);
        },
        .not_head_member => |w| {
            try buf.appendSlice(a, "got form head `");
            try buf.appendSlice(a, w.got);
            try buf.appendSlice(a, "`");
            try writeAllowedHeads(a, buf, w.allowed);
        },
        .unknown_element_kind => |w| try writeUnknownElementKind(a, buf, w.name, w.namespace),
        .ambiguous_element_kind => |k| try writeAmbiguousElementKind(a, buf, k.name, k.claimants),
        .recursion_depth => {
            try buf.appendSlice(a, "value kind chain too deep");
        },
        .not_cross_ref => |w| {
            try buf.appendSlice(a, "got `");
            try buf.appendSlice(a, w.got);
            try buf.appendSlice(a, "` (no `(");
            try buf.appendSlice(a, w.target);
            try buf.appendSlice(a, " :name …)` form declares this name)");
        },
        .cross_ref_outside_scope => |w| {
            try buf.appendSlice(a, "got `");
            try buf.appendSlice(a, w.got);
            try buf.appendSlice(a, "` outside any enclosing `(");
            try buf.appendSlice(a, w.scope_form);
            try buf.appendSlice(a, " …)` — this cross-ref is `:scope`-bound");
        },
        .union_no_branch_matched => |u| {
            try buf.appendSlice(a, "got ");
            try buf.appendSlice(a, u.got_label);
            try buf.appendSlice(a, " (no alternative matched: ");
            for (u.alternatives, 0..) |alt, i| {
                if (i > 0) try buf.appendSlice(a, " | ");
                try buf.appendSlice(a, "`");
                if (alt.namespace) |ns| {
                    try buf.appendSlice(a, ns);
                    try buf.appendSlice(a, "/");
                }
                try buf.appendSlice(a, alt.name);
                try buf.appendSlice(a, "`");
            }
            try buf.appendSlice(a, ")");
        },
        .number_below_min => |nf| try writeNumericFail(a, buf, "below minimum", nf),
        .number_above_max => |nf| try writeNumericFail(a, buf, "above maximum", nf),
        .number_at_or_below_exclusive_min => |nf| try writeNumericFail(a, buf, "must be strictly greater than", nf),
        .number_at_or_above_exclusive_max => |nf| try writeNumericFail(a, buf, "must be strictly less than", nf),
        .number_not_integer => |v| {
            const piece = try std.fmt.allocPrint(a, "value {d} is not an integer", .{v});
            try buf.appendSlice(a, piece);
        },
        .numeric_bound_unit_mismatch => |m| {
            try buf.appendSlice(a, "value unit ");
            try writeUnitOrNone(a, buf, m.value_unit);
            try buf.appendSlice(a, " does not match bound unit ");
            try writeUnitOrNone(a, buf, m.bound_unit);
        },
        .repr_out_of_range => |r| try writeReprFail(a, buf, r),
        .string_too_short => |s| {
            const piece = try std.fmt.allocPrint(
                a,
                "string length {d} is below :min-len {d}",
                .{ s.got, s.min_len },
            );
            try buf.appendSlice(a, piece);
        },
        .string_too_long => |s| {
            const piece = try std.fmt.allocPrint(
                a,
                "string length {d} is above :max-len {d}",
                .{ s.got, s.max_len },
            );
            try buf.appendSlice(a, piece);
        },
        .string_format_mismatch => |s| {
            const piece = try std.fmt.allocPrint(
                a,
                "string \"{s}\" does not satisfy :format `{s}`",
                .{ s.got, s.format },
            );
            try buf.appendSlice(a, piece);
        },
        .string_pattern_mismatch => |s| {
            const piece = try std.fmt.allocPrint(
                a,
                "string \"{s}\" does not match :pattern `{s}`",
                .{ s.got, s.pattern },
            );
            try buf.appendSlice(a, piece);
        },
    }
}

fn writeNumericFail(
    a: Allocator,
    buf: *std.ArrayList(u8),
    relation: []const u8,
    nf: MatchFail.NumericFail,
) Allocator.Error!void {
    const piece = try std.fmt.allocPrint(a, "value {d} {s} {d}", .{ nf.value, relation, nf.bound });
    try buf.appendSlice(a, piece);
    if (nf.unit) |u| {
        try buf.appendSlice(a, u);
    }
}

fn writeReprFail(
    a: Allocator,
    buf: *std.ArrayList(u8),
    rf: anytype,
) Allocator.Error!void {
    const piece = switch (rf.reason) {
        .not_integer => try std.fmt.allocPrint(
            a,
            "value {d} is not an integer — :repr `{s}` requires a whole number",
            .{ rf.value, @tagName(rf.repr) },
        ),
        .out_of_range => try std.fmt.allocPrint(
            a,
            "value {d} is out of range for :repr `{s}`",
            .{ rf.value, @tagName(rf.repr) },
        ),
    };
    try buf.appendSlice(a, piece);
}

fn writeUnitOrNone(
    a: Allocator,
    buf: *std.ArrayList(u8),
    unit: ?[]const u8,
) Allocator.Error!void {
    if (unit) |u| {
        try buf.appendSlice(a, "`");
        try buf.appendSlice(a, u);
        try buf.appendSlice(a, "`");
    } else {
        try buf.appendSlice(a, "(none)");
    }
}

fn emitDeprecatedMemberCore(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    text: []const u8,
    expected: Plugin.ValueType,
    span: Ast.Span,
    path: []const []const u8,
) Allocator.Error!void {
    const ref = switch (expected) {
        .named => |n| n,
        else => return,
    };
    const kind = switch (schema.lookupValueKind(ref.name, ref.namespace)) {
        .found => |k| k,
        else => return,
    };
    const m = kind.members orelse return;
    if (m.members.len == 0) return;
    for (m.members) |mem| {
        if (!std.mem.eql(u8, mem.name, text)) continue;
        if (!mem.deprecated) return;
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(a, "member `");
        try buf.appendSlice(a, mem.name);
        try buf.appendSlice(a, "` is deprecated");
        if (mem.deprecation_message.len > 0) {
            try buf.appendSlice(a, ": ");
            try buf.appendSlice(a, mem.deprecation_message);
        }
        try emit(a, diags, span, path, .warning, .deprecated_member, try buf.toOwnedSlice(a));
        return;
    }
}

fn emitDeprecatedMemberTree(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    expected: Plugin.ValueType,
    path: []const []const u8,
) Allocator.Error!void {
    const text: []const u8 = switch (tree.tagOf(idx)) {
        .symbol => tree.symbolText(idx),
        .string => tree.stringText(idx),
        else => return,
    };
    try emitDeprecatedMemberCore(a, diags, schema, text, expected, tree.spanOf(idx), path);
}

fn emitStringPatternUnsupportedCore(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    expected: Plugin.ValueType,
    span: Ast.Span,
    path: []const []const u8,
) Allocator.Error!void {
    const ref = switch (expected) {
        .named => |n| n,
        else => return,
    };
    const kind = switch (schema.lookupValueKind(ref.name, ref.namespace)) {
        .found => |k| k,
        else => return,
    };
    if (kind.underlying != .string) return;
    const sb = kind.string_bounds orelse return;
    const pat = sb.pattern orelse return;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "value-kind `");
    try buf.appendSlice(a, kind.name);
    try buf.appendSlice(a, "` declares `:pattern \"");
    try buf.appendSlice(a, pat);
    try buf.appendSlice(a, "\"` but this build has no regex engine — constraint is informational only");
    try emit(a, diags, span, path, .warning, .string_pattern_unsupported, try buf.toOwnedSlice(a));
}

fn emitStringPatternUnsupportedTree(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    expected: Plugin.ValueType,
    path: []const []const u8,
) Allocator.Error!void {
    if (tree.tagOf(idx) != .string) return;
    try emitStringPatternUnsupportedCore(a, diags, schema, expected, tree.spanOf(idx), path);
}

fn writeAllowedList(
    a: Allocator,
    buf: *std.ArrayList(u8),
    allowed: []const []const u8,
) Allocator.Error!void {
    if (allowed.len == 0) return;
    try buf.appendSlice(a, " (allowed: ");
    for (allowed, 0..) |u, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, "`");
        try buf.appendSlice(a, u);
        try buf.appendSlice(a, "`");
    }
    try buf.appendSlice(a, ")");
}

fn writeAllowedMembers(
    a: Allocator,
    buf: *std.ArrayList(u8),
    allowed: []const Plugin.ValueKind.MemberSet.Member,
) Allocator.Error!void {
    if (allowed.len == 0) return;
    try buf.appendSlice(a, " (allowed: ");
    for (allowed, 0..) |m, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, "`");
        try buf.appendSlice(a, m.name);
        try buf.appendSlice(a, "`");
    }
    try buf.appendSlice(a, ")");
}

fn writeAllowedHeads(
    a: Allocator,
    buf: *std.ArrayList(u8),
    allowed: []const []const u8,
) Allocator.Error!void {
    if (allowed.len == 0) return;
    try buf.appendSlice(a, " not in set [");
    for (allowed, 0..) |u, i| {
        if (i > 0) try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, u);
    }
    try buf.appendSlice(a, "]");
}

fn writeUnknownElementKind(
    a: Allocator,
    buf: *std.ArrayList(u8),
    name: []const u8,
    namespace: ?[]const u8,
) Allocator.Error!void {
    try buf.appendSlice(a, "unknown value kind `");
    if (namespace) |ns| {
        try buf.appendSlice(a, ns);
        try buf.appendSlice(a, "/");
    }
    try buf.appendSlice(a, name);
    try buf.appendSlice(a, "`");
}

fn writeAmbiguousElementKind(
    a: Allocator,
    buf: *std.ArrayList(u8),
    name: []const u8,
    claimants: []const *const Plugin.Plugin,
) Allocator.Error!void {
    try buf.appendSlice(a, "value kind `");
    try buf.appendSlice(a, name);
    try buf.appendSlice(a, "` is ambiguous — defined by [");
    for (claimants, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, p.name);
    }
    try buf.appendSlice(a, "]");
    if (claimants.len > 0) {
        try buf.appendSlice(a, "; qualify with `");
        try buf.appendSlice(a, claimants[0].name);
        try buf.appendSlice(a, "/");
        try buf.appendSlice(a, name);
        try buf.appendSlice(a, "`");
    }
}

const MAX_VALIDATE_FRAMES: u32 = 1024;
const MAX_VALIDATE_STEPS: u32 = 1024 * 1024;

const ZERO_SPAN: Ast.Span = .{ .start = 0, .end = 0 };

const SlotCtx = struct {
    form_name: []const u8,
    slot: Slot,
};

const SpecState = union(enum) {
    data_form: *const Plugin.FormSpec,
    expr_func: *const Plugin.ExprFunc,
    walk_only,
};

const MatchExtras = struct {
    unit: ?[]const u8 = null,
    vec_len: u32 = 0,
    text: ?[]const u8 = null,
    numeric: ?NumericValue = null,
};

const MatchResult = struct {
    fail: ?MatchFail = null,
    element_type: Plugin.ValueType = .any,
    element_depth: u8 = 0,
};

const StepKind = union(enum) {
    root,
    kvpair_value,
    positional: u32,
    vector_element,
};

const PathPair = struct {
    diag: []const []const u8,
    form: []const []const u8,
};

const FrameValidate = union(enum) {
    eval: struct {
        view: BinaryCursor.NodeView,
        expected: Plugin.ValueType,
        slot_ctx: ?SlotCtx,
        depth: u8,
        base_path: []const []const u8,
        step: StepKind,
        walk_opaque: bool = false,
        local_form_registry: ?[]const Plugin.FormSpec = null,
        local_form_slot_path: []const []const u8 = &.{},
    },

    form_walk: struct {
        head: []const u8,
        head_span: ?Ast.Span,
        iter: BinaryCursor.ChildIter,
        spec_state: SpecState,
        seen_keys: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
        dup_keys: std.ArrayList([]const u8),
        seen_flags: std.ArrayList([]const u8),
        argc: u32,
        pos_idx: u8 = 0,
        cand_mask: u32 = 0,
        path: []const []const u8,
        opened_scope: bool = false,
        seen_variant_keys: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS) = .initEmpty(),
        discriminant_resolved_when: ?[]const u8 = null,
        discriminant_variant_idx: ?u8 = null,
    },

    vector_walk: struct {
        iter: BinaryCursor.VectorIter,
        element_type: Plugin.ValueType,
        slot_ctx: ?SlotCtx,
        element_depth: u8,
        path: []const []const u8,
        next_index: u32,
    },
};

pub fn validateBinary(
    gpa: Allocator,
    bytes: []const u8,
    schema: Schema.Schema,
) Error!Result {
    var bins: [1][]const u8 = .{bytes};
    var fr = try validateForestBinary(gpa, &bins, schema);
    return fr.intoSingle(gpa);
}

pub fn validateForestBinary(
    gpa: Allocator,
    binaries: []const []const u8,
    schema: Schema.Schema,
) Error!ForestResult {
    var index_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer index_arena.deinit();

    var results = try gpa.alloc(Result, binaries.len);
    errdefer gpa.free(results);

    var inited: usize = 0;
    errdefer for (results[0..inited]) |*r| r.deinit();
    for (0..binaries.len) |i| {
        results[i] = .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .diagnostics = &.{},
        };
        inited = i + 1;
    }

    var diags_lists = try gpa.alloc(std.ArrayList(Diagnostic), binaries.len);
    defer gpa.free(diags_lists);
    for (0..binaries.len) |i| diags_lists[i] = .empty;

    var index = try buildCrossRefIndexBinary(
        index_arena.allocator(),
        gpa,
        schema,
        binaries,
        results,
        diags_lists,
    );

    var scope_heads_validation = try schemaScopeHeads(gpa, schema);
    defer freeSchemaScopeHeads(gpa, &scope_heads_validation);

    for (binaries, 0..) |bytes, i| {
        try validateOneBinary(
            results[i].arena.allocator(),
            gpa,
            bytes,
            schema,
            &index,
            .tree(@intCast(i)),
            &scope_heads_validation,
            &diags_lists[i],
        );
    }

    for (0..binaries.len) |i| {
        results[i].diagnostics = diags_lists[i].items;
    }

    return .{
        .results = results,
        .cross_ref_index = index,
        .index_arena = index_arena,
    };
}

fn validateOneBinary(
    a: Allocator,
    gpa: Allocator,
    bytes: []const u8,
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_heads: *const std.StringHashMapUnmanaged(void),
    diags: *std.ArrayList(Diagnostic),
) Error!void {
    var cursor = try BinaryCursor.Cursor.init(bytes);
    var root_iter = try cursor.rootIter();

    var frames: std.ArrayList(FrameValidate) = .empty;
    defer frames.deinit(gpa);
    var scope_stack: std.ArrayList(ScopeFrame) = .empty;
    defer scope_stack.deinit(gpa);
    var canon_buf: std.ArrayList(u8) = .empty;
    defer canon_buf.deinit(gpa);

    while (try root_iter.next()) |root_view| {
        try frames.append(gpa, .{ .eval = .{
            .view = root_view,
            .expected = .any,
            .slot_ctx = null,
            .depth = 0,
            .base_path = &.{},
            .step = .root,
        } });

        var step: u32 = 0;
        while (frames.items.len > 0) {
            if (step >= MAX_VALIDATE_STEPS) return error.DepthExceeded;
            if (frames.items.len > MAX_VALIDATE_FRAMES) return error.DepthExceeded;
            step += 1;

            const f = frames.pop().?;
            switch (f) {
                .eval => |e| try processEvalValidate(a, gpa, &cursor, schema, cross_index, tree_scope, scope_heads, &scope_stack, &canon_buf, e, &frames, diags),
                .form_walk => |fw| try processFormWalkValidate(a, gpa, fw, &frames, &scope_stack, diags),
                .vector_walk => |vw| try processVectorWalkValidate(a, gpa, vw, &frames),
            }
        }
    }
}

fn processEvalValidate(
    a: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_heads: *const std.StringHashMapUnmanaged(void),
    scope_stack: *std.ArrayList(ScopeFrame),
    canon_buf: *std.ArrayList(u8),
    e: anytype,
    frames: *std.ArrayList(FrameValidate),
    diags: *std.ArrayList(Diagnostic),
) Error!void {
    const view = e.view;

    var extras: MatchExtras = .{};
    var maybe_iter: ?BinaryCursor.VectorIter = null;
    var maybe_form: ?BinaryCursor.FormView = null;

    switch (view.kind) {
        .nil => try BinaryCursor.readNil(cursor, view),
        .boolean => _ = try BinaryCursor.readBoolean(cursor, view),
        .number => extras.numeric = switch (view.tag_byte) {
            0x03 => NumericValue{ .f = try BinaryCursor.readNumber(cursor, view) },
            0x0B => NumericValue{ .i = try BinaryCursor.readNumberI64(cursor, view) },
            0x0C => NumericValue{ .u = try BinaryCursor.readNumberU64(cursor, view) },
            else => unreachable,
        },
        .number_with_unit => {
            const nu = try BinaryCursor.readNumberWithUnit(cursor, view);
            extras.unit = nu.unit;
            extras.numeric = NumericValue{ .f = nu.value };
        },
        .date => _ = try BinaryCursor.readDate(cursor, view),
        .time => _ = try BinaryCursor.readTime(cursor, view),
        .string => extras.text = try BinaryCursor.readString(cursor, view),
        .keyword => _ = try BinaryCursor.readKeyword(cursor, view),
        .symbol => extras.text = try BinaryCursor.readSymbol(cursor, view),
        .vector => {
            const it = try BinaryCursor.readVector(cursor, view);
            extras.vec_len = it.remaining;
            maybe_iter = it;
        },
        .form => {
            maybe_form = try BinaryCursor.readForm(cursor, view);
        },
    }

    const head_for_path: []const u8 = if (maybe_form) |fv| fv.head else "";
    const paths = try computeBinaryPathPair(a, e.base_path, e.step, view.kind, head_for_path);

    var element_type: Plugin.ValueType = .any;
    var element_depth: u8 = 0;

    if (e.slot_ctx) |ctx| {
        if (view.kind != .form) {
            const result = try matchAgainstExpected(a, schema, cross_index, tree_scope, scope_stack.items, view, e.expected, e.depth, extras);
            if (result.fail) |f| {
                try emitTypeMismatchBinary(a, diags, view, paths.diag, ctx, e.expected, f, extras);
            } else if (extras.text) |t| {
                try emitDeprecatedMemberCore(a, diags, schema, t, e.expected, view.span orelse ZERO_SPAN, paths.diag);
                if (view.kind == .string) {
                    try emitStringPatternUnsupportedCore(a, diags, schema, e.expected, view.span orelse ZERO_SPAN, paths.diag);
                }
            }
            element_type = result.element_type;
            element_depth = result.element_depth;
        } else if (resolveFormHeadKind(schema, e.expected)) |kind| {
            if (kind.heads) |hs| {
                const head = maybe_form.?.head;
                var matched = false;
                for (hs.names) |n| if (std.mem.eql(u8, n, head)) {
                    matched = true;
                    break;
                };
                if (!matched) {
                    var head_extras = extras;
                    head_extras.text = head;
                    try emitTypeMismatchBinary(
                        a,
                        diags,
                        view,
                        paths.diag,
                        ctx,
                        e.expected,
                        .{ .not_head_member = .{ .got = head, .allowed = hs.names } },
                        head_extras,
                    );
                }
            }
        } else if (!isAnyType(e.expected) and e.expected != .form and !resolvesToUnion(schema, e.expected)) {
            const fv = maybe_form.?;
            const res = resolveFormExpressionBinary(schema, fv.head, fv.namespace, fv.children.remaining);
            const verdict: ?MatchFail = blk: {
                if (e.expected == .expr) {
                    break :blk switch (res) {
                        .expr => null,
                        .data_form => MatchFail{ .wrong_underlying = typeLabel(e.expected) },
                        .unresolved => null,
                    };
                }
                break :blk switch (res) {
                    .unresolved => null,
                    .data_form => MatchFail{ .wrong_underlying = typeLabel(e.expected) },
                    .expr => |x| sub: {
                        const declared = x.result orelse break :sub null;
                        break :sub switch (declaredResultMatchesExpected(schema, declared, e.expected)) {
                            .yes, .unknown => null,
                            .no => MatchFail{ .wrong_underlying = typeLabel(e.expected) },
                        };
                    },
                };
            };
            if (verdict) |f| {
                try emitTypeMismatchBinary(a, diags, view, paths.diag, ctx, e.expected, f, extras);
            }
        }
    }

    if (e.walk_opaque) {
        if (maybe_iter) |it| {
            var vit = it;
            while (try vit.next()) |elem| try BinaryCursor.skipBody(cursor, elem);
        } else if (maybe_form) |fv| {
            var cit = fv.children;
            while (try cit.next()) |ce| try BinaryCursor.skipBody(cursor, ce.value);
        }
    } else if (maybe_iter) |it| {
        try frames.append(gpa, .{ .vector_walk = .{
            .iter = it,
            .element_type = element_type,
            .slot_ctx = if (element_type == .any) null else e.slot_ctx,
            .element_depth = element_depth,
            .path = paths.diag,
            .next_index = 0,
        } });
    } else if (maybe_form) |fv| {
        try scheduleFormWalkValidate(a, gpa, schema, fv, paths.form, frames, diags, scope_heads, scope_stack, canon_buf, tree_scope, e.local_form_registry, e.local_form_slot_path);
    }
}

fn scheduleFormWalkValidate(
    a: Allocator,
    gpa: Allocator,
    schema: Schema.Schema,
    fv: BinaryCursor.FormView,
    form_path: []const []const u8,
    frames: *std.ArrayList(FrameValidate),
    diags: *std.ArrayList(Diagnostic),
    scope_heads: *const std.StringHashMapUnmanaged(void),
    scope_stack: *std.ArrayList(ScopeFrame),
    canon_buf: *std.ArrayList(u8),
    tree_scope: ScopeId,
    local_registry: ?[]const Plugin.FormSpec,
    local_slot_path: []const []const u8,
) Error!void {
    const head = fv.head;
    const head_span = fv.head_span orelse ZERO_SPAN;
    const argc = fv.children.remaining;

    var spec_state: SpecState = .walk_only;

    if (head.len > 0) {
        if (fv.namespace == null and local_registry != null) {
            const reg = local_registry.?;
            const local_hit: ?*const Plugin.FormSpec = blk: {
                for (reg) |*lf| {
                    if (std.mem.eql(u8, lf.name, head)) break :blk lf;
                }
                break :blk null;
            };
            if (local_hit) |lf| {
                spec_state = .{ .data_form = lf };
            } else switch (schema.lookupForm(head, null)) {
                .found => |hit| spec_state = .{ .data_form = hit.form },
                .ambiguous => |amb| try emitAmbiguous(a, diags, head_span, form_path, "form", head, amb.slice()),
                .not_found => try emitUnknownLocalForm(a, diags, head_span, local_slot_path, head, reg),
            }
        } else {
            const form_hit = schema.lookupForm(head, fv.namespace);
            switch (form_hit) {
                .found => |hit| spec_state = .{ .data_form = hit.form },
                .ambiguous => |amb| try emitAmbiguous(a, diags, head_span, form_path, "form", head, amb.slice()),
                .not_found => {
                    const expr_hit = schema.lookupExprFunc(head, fv.namespace);
                    switch (expr_hit) {
                        .found => |hit| spec_state = .{ .expr_func = hit.func },
                        .ambiguous => |amb| try emitAmbiguous(a, diags, head_span, form_path, "expression", head, amb.slice()),
                        .not_found => try emitUnknown(a, diags, head_span, form_path, head, fv.namespace),
                    }
                },
            }
        }
    }

    const cand_mask: u32 = switch (spec_state) {
        .expr_func => |func| if (func.signatures != null)
            overloadInitialMask(func.*, argc)
        else
            0,
        else => 0,
    };

    var opened_scope = false;
    const form_pos: u32 = @intCast(fv.children.cursor.pos);
    if (scope_heads.count() > 0) {
        if (canonicalFormNameBuf(gpa, canon_buf, schema, head, fv.namespace) catch null) |canon| {
            if (scope_heads.getEntry(canon)) |sh_entry| {
                try scope_stack.append(gpa, .{
                    .canonical = sh_entry.key_ptr.*,
                    .scope_id = .lexical(tree_scope.treeIdx(), form_pos),
                });
                opened_scope = true;
            }
        }
    }

    try frames.append(gpa, .{ .form_walk = .{
        .head = head,
        .head_span = fv.head_span,
        .iter = fv.children,
        .spec_state = spec_state,
        .seen_keys = std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS).initEmpty(),
        .dup_keys = .empty,
        .seen_flags = .empty,
        .argc = argc,
        .cand_mask = cand_mask,
        .path = form_path,
        .opened_scope = opened_scope,
    } });
}

fn processFormWalkValidate(
    a: Allocator,
    gpa: Allocator,
    fw: anytype,
    frames: *std.ArrayList(FrameValidate),
    scope_stack: *std.ArrayList(ScopeFrame),
    diags: *std.ArrayList(Diagnostic),
) Error!void {
    var iter = fw.iter;

    if (iter.remaining == 0) {
        _ = try iter.next();
        try emitEndOfFormBinary(a, diags, fw);
        if (fw.opened_scope and scope_stack.items.len > 0) {
            _ = scope_stack.pop();
        }
        return;
    }

    const entry = (try iter.next()) orelse unreachable;

    var expected: Plugin.ValueType = .any;
    var slot_ctx: ?SlotCtx = null;
    var seen_keys = fw.seen_keys;
    var seen_variant_keys = fw.seen_variant_keys;
    var dup_keys = fw.dup_keys;
    var seen_flags = fw.seen_flags;
    var discriminant_resolved_when = fw.discriminant_resolved_when;
    var discriminant_variant_idx = fw.discriminant_variant_idx;
    var next_cand_mask = fw.cand_mask;
    var suppress_descent = false;
    var local_registry: ?[]const Plugin.FormSpec = null;
    var local_slot_path: []const []const u8 = &.{};

    const child_step: StepKind = switch (entry.kind) {
        .keyword => .kvpair_value,
        .positional => .{ .positional = fw.pos_idx },
        _ => .{ .positional = fw.pos_idx },
    };

    const child_base: []const []const u8 = switch (entry.kind) {
        .keyword => try appendStep(a, fw.path, entry.key.?),
        .positional => fw.path,
        _ => fw.path,
    };

    switch (fw.spec_state) {
        .walk_only => {},
        .data_form => |spec| switch (entry.kind) {
            .keyword => {
                const key = entry.key.?;
                var is_dup = false;
                for (dup_keys.items) |prior| {
                    if (std.mem.eql(u8, prior, key)) {
                        is_dup = true;
                        break;
                    }
                }
                if (is_dup) {
                    try emit(a, diags, entry.key_span orelse ZERO_SPAN, child_base, .err, .duplicate_key, try std.fmt.allocPrint(
                        a,
                        "duplicate keyword `:{s}` in form `{s}`",
                        .{ key, spec.name },
                    ));
                } else {
                    try dup_keys.append(a, key);
                }

                var found = false;
                for (spec.keys, 0..) |k, ki| {
                    if (std.mem.eql(u8, k.name, key)) {
                        found = true;
                        if (ki < Plugin.MAX_FORM_KEYS) seen_keys.set(ki);
                        expected = k.value_type;
                        slot_ctx = .{ .form_name = spec.name, .slot = .{ .key = k.name } };
                        suppress_descent = k.walk_opaque;
                        if (k.local_forms.len > 0 and entry.value.kind == .form) {
                            local_registry = k.local_forms;
                            local_slot_path = child_base;
                        }
                        if (spec.discriminant_idx) |didx| {
                            if (ki == didx and entry.value.kind == .symbol) {
                                if (BinaryCursor.peekSymbol(iter.cursor, entry.value)) |sym| {
                                    const vs = spec.variants orelse &.{};
                                    for (vs, 0..) |v, vi| {
                                        if (std.mem.eql(u8, v.when, sym)) {
                                            discriminant_resolved_when = v.when;
                                            discriminant_variant_idx = @intCast(vi);
                                            break;
                                        }
                                    }
                                } else |_| {}
                            }
                        }
                        break;
                    }
                }
                if (!found) {
                    if (discriminant_variant_idx) |vi| {
                        const v = spec.variants.?[vi];
                        for (v.keys, 0..) |vk, vki| {
                            if (std.mem.eql(u8, vk.name, key)) {
                                found = true;
                                if (vki < Plugin.MAX_FORM_KEYS) seen_variant_keys.set(vki);
                                expected = vk.value_type;
                                slot_ctx = .{ .form_name = spec.name, .slot = .{ .key = vk.name } };
                                suppress_descent = vk.walk_opaque;
                                if (vk.local_forms.len > 0 and entry.value.kind == .form) {
                                    local_registry = vk.local_forms;
                                    local_slot_path = child_base;
                                }
                                break;
                            }
                        }
                    }
                }
                if (!found and !spec.open) {
                    if (spec.discriminant_idx != null and discriminant_resolved_when == null) {
                        const dname = spec.discriminant_name orelse "kind";
                        try emit(a, diags, entry.key_span orelse ZERO_SPAN, child_base, .err, .unknown_key, try std.fmt.allocPrint(
                            a,
                            "unknown keyword `:{s}` in form `{s}` — `:{s}` must be set before variant-only keys",
                            .{ key, spec.name, dname },
                        ));
                    } else {
                        var msg_buf: std.ArrayList(u8) = .empty;
                        try msg_buf.appendSlice(a, "unknown keyword `:");
                        try msg_buf.appendSlice(a, key);
                        try msg_buf.appendSlice(a, "` in form `");
                        try msg_buf.appendSlice(a, spec.name);
                        try msg_buf.appendSlice(a, "`");
                        if (discriminant_resolved_when) |w| {
                            try msg_buf.appendSlice(a, " (variant `:when ");
                            try msg_buf.appendSlice(a, w);
                            try msg_buf.appendSlice(a, "`)");
                        }
                        try emit(a, diags, entry.key_span orelse ZERO_SPAN, child_base, .err, .unknown_key, try msg_buf.toOwnedSlice(a));
                    }
                }
            },
            .positional => {
                switch (spec.positional) {
                    .none => if (!spec.open) {
                        const step: []const u8 = if (entry.value.kind == .form) blk: {
                            const h = try BinaryCursor.peekFormHead(iter.cursor, entry.value);
                            if (h.len > 0) break :blk try a.dupe(u8, h);
                            break :blk try indexStep(a, fw.pos_idx);
                        } else try indexStep(a, fw.pos_idx);
                        const pos_path = try extendPath(a, fw.path, step);
                        try emit(a, diags, entry.value.span orelse ZERO_SPAN, pos_path, .err, .positional_not_allowed, try std.fmt.allocPrint(
                            a,
                            "form `{s}` does not accept positional children",
                            .{spec.name},
                        ));
                    },
                    .any => {},
                    .kind => |kind_ref| {
                        expected = .{ .named = kind_ref };
                        slot_ctx = .{ .form_name = spec.name, .slot = .positional };
                    },
                    .flag_set => |fs| {
                        const step: []const u8 = if (entry.value.kind == .form) blk: {
                            const h = try BinaryCursor.peekFormHead(iter.cursor, entry.value);
                            if (h.len > 0) break :blk try a.dupe(u8, h);
                            break :blk try indexStep(a, fw.pos_idx);
                        } else try indexStep(a, fw.pos_idx);
                        const pos_path = try extendPath(a, fw.path, step);
                        const is_kw = entry.value.kind == .keyword;
                        const got: []const u8 = if (is_kw) try BinaryCursor.peekKeyword(iter.cursor, entry.value) else "";
                        switch (classifyFlag(is_kw, got, fs.flags)) {
                            .ok => {
                                var dup = false;
                                for (seen_flags.items) |prior| {
                                    if (std.mem.eql(u8, prior, got)) {
                                        dup = true;
                                        break;
                                    }
                                }
                                if (dup) {
                                    try emit(a, diags, entry.value.span orelse ZERO_SPAN, pos_path, .err, .duplicate_positional_flag, try flagDuplicateMsg(a, spec.name, got));
                                } else {
                                    try seen_flags.append(a, try a.dupe(u8, got));
                                }
                            },
                            .wrong_shape => try emit(a, diags, entry.value.span orelse ZERO_SPAN, pos_path, .err, .wrong_underlying, try flagWrongShapeMsg(a, spec.name)),
                            .not_member => try emit(a, diags, entry.value.span orelse ZERO_SPAN, pos_path, .err, .not_flag_member, try flagNotMemberMsg(a, spec.name, got, fs.flags)),
                        }
                    },
                }
            },
            _ => unreachable,
        },
        .expr_func => |func| {
            if (entry.kind == .keyword) {
                if (anyLabeledSignature(func.*)) {} else {
                    try emit(a, diags, entry.key_span orelse ZERO_SPAN, child_base, .err, .expr_kvpair_not_allowed, try std.fmt.allocPrint(
                        a,
                        "expression `{s}` does not accept keyword argument `:{s}`",
                        .{ func.name, entry.key.? },
                    ));
                }
            } else if (func.signatures != null) {
                if (entry.value.kind != .symbol and entry.value.kind != .form) {
                    const accept = overloadAcceptMask(func.*, fw.pos_idx, entry.value.kind);
                    const new_mask = fw.cand_mask & accept;
                    if (fw.cand_mask != 0 and new_mask == 0) {
                        const step = try indexStep(a, fw.pos_idx);
                        const arg_path = try extendPath(a, fw.path, step);
                        try emitOverloadMismatch(
                            a,
                            diags,
                            entry.value.span orelse ZERO_SPAN,
                            arg_path,
                            func.*,
                            fw.pos_idx,
                            fw.cand_mask,
                            entry.value.kind,
                        );
                    }
                    next_cand_mask = new_mask;
                }
            } else if (func.paramType(fw.pos_idx)) |t| {
                if (entry.value.kind != .symbol) {
                    expected = t;
                    slot_ctx = .{ .form_name = func.name, .slot = .{ .expr_arg = fw.pos_idx } };
                }
            }
        },
    }

    var next_pos_idx = fw.pos_idx;
    if (entry.kind == .positional and next_pos_idx != std.math.maxInt(u8)) {
        next_pos_idx += 1;
    }

    try frames.append(gpa, .{ .form_walk = .{
        .head = fw.head,
        .head_span = fw.head_span,
        .iter = iter,
        .spec_state = fw.spec_state,
        .seen_keys = seen_keys,
        .seen_variant_keys = seen_variant_keys,
        .dup_keys = dup_keys,
        .seen_flags = seen_flags,
        .argc = fw.argc,
        .pos_idx = next_pos_idx,
        .cand_mask = next_cand_mask,
        .path = fw.path,
        .opened_scope = fw.opened_scope,
        .discriminant_resolved_when = discriminant_resolved_when,
        .discriminant_variant_idx = discriminant_variant_idx,
    } });
    try frames.append(gpa, .{ .eval = .{
        .view = entry.value,
        .expected = expected,
        .slot_ctx = slot_ctx,
        .depth = 0,
        .base_path = child_base,
        .step = child_step,
        .walk_opaque = suppress_descent,
        .local_form_registry = local_registry,
        .local_form_slot_path = local_slot_path,
    } });
}

fn emitEndOfFormBinary(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    fw: anytype,
) Allocator.Error!void {
    const head_span = fw.head_span orelse ZERO_SPAN;
    switch (fw.spec_state) {
        .walk_only => {},
        .data_form => |spec| {
            if (spec.open) return;
            if (spec.discriminant_idx) |didx| {
                if (didx < Plugin.MAX_FORM_KEYS and !fw.seen_keys.isSet(didx)) {
                    const dname = spec.discriminant_name orelse spec.keys[didx].name;
                    try emit(a, diags, head_span, fw.path, .err, .missing_discriminant_key, try std.fmt.allocPrint(
                        a,
                        "form `{s}` is missing required discriminant `:{s}`",
                        .{ spec.name, dname },
                    ));
                }
            }
            for (spec.keys, 0..) |k, ki| {
                if (k.effectiveOptional()) continue;
                if (ki < Plugin.MAX_FORM_KEYS and fw.seen_keys.isSet(ki)) continue;
                if (spec.discriminant_idx) |didx| {
                    if (ki == didx) continue;
                }
                if (keyInExclusiveGroup(spec.exclusive_groups, k.name)) continue;
                try emit(a, diags, head_span, fw.path, .err, .missing_required_key, try std.fmt.allocPrint(
                    a,
                    "form `{s}` is missing required keyword `:{s}`",
                    .{ spec.name, k.name },
                ));
            }
            try emitExclusiveGroupDiagnosticsTree(
                a,
                diags,
                spec.exclusive_groups,
                spec.keys,
                fw.seen_keys,
                null,
                spec.name,
                null,
                head_span,
                fw.path,
            );
            if (fw.discriminant_variant_idx) |vi| {
                const v = spec.variants.?[vi];
                for (v.keys, 0..) |vk, vki| {
                    if (vk.effectiveOptional()) continue;
                    if (vki < Plugin.MAX_FORM_KEYS and fw.seen_variant_keys.isSet(vki)) continue;
                    var present = false;
                    for (fw.dup_keys.items) |k| {
                        if (std.mem.eql(u8, k, vk.name)) {
                            present = true;
                            break;
                        }
                    }
                    if (present) continue;
                    if (keyInExclusiveGroup(v.exclusive_groups, vk.name)) continue;
                    try emit(a, diags, head_span, fw.path, .err, .missing_required_key, try std.fmt.allocPrint(
                        a,
                        "form `{s}` (variant `:when {s}`) is missing required keyword `:{s}`",
                        .{ spec.name, v.when, vk.name },
                    ));
                }
                try emitExclusiveGroupDiagnosticsTree(
                    a,
                    diags,
                    v.exclusive_groups,
                    v.keys,
                    fw.seen_variant_keys,
                    null,
                    spec.name,
                    v.when,
                    head_span,
                    fw.path,
                );
            }
        },
        .expr_func => |func| {
            if (!func.checkArity(fw.argc)) {
                try emitArity(a, diags, head_span, fw.path, func.*, fw.argc);
            }
        },
    }
}

fn processVectorWalkValidate(
    a: Allocator,
    gpa: Allocator,
    vw: anytype,
    frames: *std.ArrayList(FrameValidate),
) Error!void {
    var iter = vw.iter;
    if (iter.remaining == 0) return;

    const elem_view = (try iter.next()) orelse unreachable;

    const idx_step = try indexStep(a, vw.next_index);
    const elem_base = try extendPath(a, vw.path, idx_step);

    try frames.append(gpa, .{ .vector_walk = .{
        .iter = iter,
        .element_type = vw.element_type,
        .slot_ctx = vw.slot_ctx,
        .element_depth = vw.element_depth,
        .path = vw.path,
        .next_index = vw.next_index + 1,
    } });
    try frames.append(gpa, .{ .eval = .{
        .view = elem_view,
        .expected = vw.element_type,
        .slot_ctx = vw.slot_ctx,
        .depth = vw.element_depth,
        .base_path = elem_base,
        .step = .vector_element,
    } });
}

const Resolved = union(enum) {
    primitive: Plugin.ValueType,
    kind: struct { ptr: *const Plugin.ValueKind, depth: u8 },
    fail: MatchFail,
};

fn resolveExpected(
    a: Allocator,
    schema: Schema.Schema,
    expected: Plugin.ValueType,
    depth: u8,
) Allocator.Error!Resolved {
    var current = expected;
    while (true) {
        switch (current) {
            .named => |ref| {
                if (resolvePrimitiveShortcut(ref.name)) |p| {
                    current = p;
                    continue;
                }
                switch (schema.lookupValueKind(ref.name, ref.namespace)) {
                    .found => |k| {
                        const next_d = depth + 1;
                        if (next_d >= Schema.MAX_KIND_DEPTH) return .{ .fail = .recursion_depth };
                        return .{ .kind = .{ .ptr = k, .depth = next_d } };
                    },
                    .not_found => return .{ .fail = .{ .unknown_element_kind = .{
                        .name = ref.name,
                        .namespace = ref.namespace,
                    } } },
                    .ambiguous => |amb| return .{ .fail = .{ .ambiguous_element_kind = .{
                        .name = ref.name,
                        .claimants = try a.dupe(*const Plugin.Plugin, amb.slice()),
                    } } },
                }
            },
            else => return .{ .primitive = current },
        }
    }
}

fn matchAgainstExpected(
    a: Allocator,
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    view: BinaryCursor.NodeView,
    expected: Plugin.ValueType,
    depth: u8,
    extras: MatchExtras,
) Allocator.Error!MatchResult {
    return switch (try resolveExpected(a, schema, expected, depth)) {
        .fail => |f| .{ .fail = f },
        .primitive => |p| matchPrimitiveBinary(view, p),
        .kind => |kr| try matchKindBinary(a, schema, view, kr.ptr, kr.depth, cross_index, tree_scope, scope_chain, extras),
    };
}

fn matchPrimitiveBinary(view: BinaryCursor.NodeView, p: Plugin.ValueType) MatchResult {
    const tag = view.kind;
    return switch (p) {
        .any => .{},
        .number => switch (tag) {
            .number, .number_with_unit => .{},
            else => .{ .fail = .{ .wrong_underlying = "number" } },
        },
        .string => if (tag == .string) .{} else .{ .fail = .{ .wrong_underlying = "string" } },
        .symbol => if (tag == .symbol) .{} else .{ .fail = .{ .wrong_underlying = "symbol" } },
        .boolean => if (tag == .boolean) .{} else .{ .fail = .{ .wrong_underlying = "boolean" } },
        .nil => if (tag == .nil) .{} else .{ .fail = .{ .wrong_underlying = "nil" } },
        .vector => if (tag == .vector) .{} else .{ .fail = .{ .wrong_underlying = "vector" } },
        .form, .expr => .{ .fail = .{ .wrong_underlying = "form" } },
        .named => unreachable,
    };
}

fn matchKindBinary(
    a: Allocator,
    schema: Schema.Schema,
    view: BinaryCursor.NodeView,
    kind: *const Plugin.ValueKind,
    depth: u8,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    extras: MatchExtras,
) Allocator.Error!MatchResult {
    const tag = view.kind;
    return switch (kind.underlying) {
        .number => blk: {
            std.debug.assert(kind.members == null);
            const unit_fail: ?MatchFail = switch (tag) {
                .number => sub: {
                    if (kind.unit) |u| if (u.required) break :sub @as(?MatchFail, .{ .unit_missing = u.allowed });
                    break :sub @as(?MatchFail, null);
                },
                .number_with_unit => sub: {
                    if (kind.unit) |u| {
                        const got = extras.unit.?;
                        if (u.reject) break :sub @as(?MatchFail, .{ .unit_forbidden = got });
                        if (u.allowed.len != 0) {
                            var ok: bool = false;
                            for (u.allowed) |w| if (std.mem.eql(u8, w, got)) {
                                ok = true;
                                break;
                            };
                            if (!ok) break :sub @as(?MatchFail, .{ .unit_wrong = .{ .got = got, .allowed = u.allowed } });
                        }
                    }
                    break :sub @as(?MatchFail, null);
                },
                else => break :blk .{ .fail = .{ .wrong_underlying = "number" } },
            };
            if (unit_fail) |f| break :blk .{ .fail = f };
            if (kind.numeric) |nb| if (extras.numeric) |v| {
                if (checkNumericBoundsValue(v, extras.unit, nb)) |f| break :blk .{ .fail = f };
            };
            if (kind.repr) |r| if (extras.numeric) |v| {
                if (checkReprValue(v, r)) |f| break :blk .{ .fail = f };
            };
            break :blk .{};
        },
        .string => blk: {
            if (tag != .string) break :blk .{ .fail = .{ .wrong_underlying = "string" } };
            if (kind.members) |m| {
                if (m.members.len != 0) {
                    const got = extras.text.?;
                    var matched: bool = false;
                    for (m.members) |v| if (std.mem.eql(u8, v.name, got)) {
                        matched = true;
                        break;
                    };
                    if (!matched) break :blk .{ .fail = .{ .not_member = .{ .got = got, .allowed = m.members } } };
                }
            }
            if (kind.string_bounds) |sb| {
                const text = extras.text.?;
                if (checkStringBoundsValue(text, sb)) |f| break :blk .{ .fail = f };
            }
            break :blk .{};
        },
        .symbol => blk: {
            if (tag != .symbol) break :blk .{ .fail = .{ .wrong_underlying = "symbol" } };
            if (kind.cross_ref) |cr| {
                const got = extras.text.?;
                const canonical = (try canonicalCrossRefTarget(a, schema, cr.target_form)) orelse {
                    break :blk .{ .fail = .{ .not_cross_ref = .{ .got = got, .target = cr.target_form } } };
                };
                const lookup_scope: ScopeId = if (cr.scope_form) |sf| sub: {
                    const scope_canonical = (try canonicalCrossRefTarget(a, schema, sf)) orelse {
                        break :blk .{ .fail = .{ .not_cross_ref = .{ .got = got, .target = canonical } } };
                    };
                    break :sub findNearestScope(scope_chain, scope_canonical) orelse {
                        break :blk .{ .fail = .{ .cross_ref_outside_scope = .{ .got = got, .scope_form = scope_canonical } } };
                    };
                } else tree_scope;
                const ref_span = view.span orelse ZERO_SPAN;
                try cross_index.appendReference(lookup_scope, canonical, got, .{
                    .tree_idx = tree_scope.treeIdx(),
                    .node_idx = .invalid,
                    .form_span = ref_span,
                    .name_span = ref_span,
                    .scope = lookup_scope,
                });
                if (cross_index.contains(lookup_scope, canonical, got)) break :blk .{};
                break :blk .{ .fail = .{ .not_cross_ref = .{ .got = got, .target = canonical } } };
            }
            if (kind.members) |m| {
                if (m.members.len == 0) break :blk .{};
                const got = extras.text.?;
                for (m.members) |v| if (std.mem.eql(u8, v.name, got)) break :blk .{};
                break :blk .{ .fail = .{ .not_member = .{ .got = got, .allowed = m.members } } };
            }
            break :blk .{};
        },
        .form => blk: {
            std.debug.assert(kind.members == null);
            break :blk if (tag == .form) .{} else .{ .fail = .{ .wrong_underlying = "form" } };
        },
        .vector => blk: {
            std.debug.assert(kind.members == null);
            if (tag != .vector) break :blk .{ .fail = .{ .wrong_underlying = "vector" } };
            if (kind.vector) |vs| {
                if (vs.len) |want| {
                    if (extras.vec_len != want) break :blk .{
                        .fail = .{ .wrong_vector_len = .{ .want = want, .got = extras.vec_len } },
                    };
                }
                if (vs.min_len) |mn| {
                    if (extras.vec_len < mn) break :blk .{
                        .fail = .{ .vector_too_short = .{ .got = extras.vec_len, .min_len = mn } },
                    };
                }
                if (vs.max_len) |mx| {
                    if (extras.vec_len > mx) break :blk .{
                        .fail = .{ .vector_too_long = .{ .got = extras.vec_len, .max_len = mx } },
                    };
                }
                break :blk .{
                    .element_type = .{ .named = vs.element },
                    .element_depth = depth,
                };
            }
            break :blk .{};
        },
        .union_of => blk: {
            const us = kind.union_of orelse break :blk .{ .fail = .{ .wrong_underlying = "union" } };
            for (us.alternatives) |alt_name| {
                const result = try matchAgainstExpected(
                    a,
                    schema,
                    cross_index,
                    tree_scope,
                    scope_chain,
                    view,
                    .{ .named = alt_name },
                    depth,
                    extras,
                );
                if (result.fail == null) break :blk result;
            }
            break :blk .{ .fail = .{ .union_no_branch_matched = .{
                .got_label = nodeKindLabelBinary(tag),
                .alternatives = us.alternatives,
            } } };
        },
    };
}

fn nodeKindLabelBinary(kind: Ast.ValueKind) []const u8 {
    return switch (kind) {
        .number, .number_with_unit => "number",
        .string => "string",
        .keyword => "keyword",
        .symbol => "symbol",
        .boolean => "boolean",
        .nil => "nil",
        .date => "date",
        .time => "time",
        .vector => "vector",
        .form => "form",
    };
}

fn emitTypeMismatchBinary(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    view: BinaryCursor.NodeView,
    path: []const []const u8,
    ctx: SlotCtx,
    expected: Plugin.ValueType,
    fail: MatchFail,
    extras: MatchExtras,
) Allocator.Error!void {
    var buf: std.ArrayList(u8) = .empty;
    const noun: []const u8 = switch (ctx.slot) {
        .positional, .key => "form",
        .expr_arg => "expression",
    };
    try buf.appendSlice(a, noun);
    try buf.appendSlice(a, " `");
    try buf.appendSlice(a, ctx.form_name);
    try buf.appendSlice(a, "` ");
    switch (ctx.slot) {
        .positional => try buf.appendSlice(a, "positional argument"),
        .key => |k| {
            try buf.appendSlice(a, "keyword `:");
            try buf.appendSlice(a, k);
            try buf.appendSlice(a, "`");
        },
        .expr_arg => |i| {
            try buf.appendSlice(a, "argument ");
            const piece = try std.fmt.allocPrint(a, "{d}", .{i});
            try buf.appendSlice(a, piece);
        },
    }
    try buf.appendSlice(a, " expects ");
    try describeType(a, &buf, expected);
    try buf.appendSlice(a, ", ");
    try describeFailBinary(a, &buf, view, fail, extras);
    const code: Diagnostic.Code = switch (ctx.slot) {
        .expr_arg => .expr_type_mismatch,
        .positional, .key => matchFailToCode(fail),
    };
    try emit(a, diags, view.span orelse ZERO_SPAN, path, .err, code, try buf.toOwnedSlice(a));
}

fn describeFailBinary(
    a: Allocator,
    buf: *std.ArrayList(u8),
    view: BinaryCursor.NodeView,
    fail: MatchFail,
    extras: MatchExtras,
) Allocator.Error!void {
    switch (fail) {
        .wrong_underlying => {
            try buf.appendSlice(a, "got ");
            try describeNodeBinary(a, buf, view, extras);
        },
        .wrong_vector_len => |w| {
            const piece = try std.fmt.allocPrint(a, "got vector of length {d}", .{w.got});
            try buf.appendSlice(a, piece);
        },
        .vector_too_short => |v| {
            const piece = try std.fmt.allocPrint(a, "got vector of length {d}, below :min-len {d}", .{ v.got, v.min_len });
            try buf.appendSlice(a, piece);
        },
        .vector_too_long => |v| {
            const piece = try std.fmt.allocPrint(a, "got vector of length {d}, above :max-len {d}", .{ v.got, v.max_len });
            try buf.appendSlice(a, piece);
        },
        .element_at => unreachable,
        .unit_missing => |allowed| {
            try buf.appendSlice(a, "got number without unit");
            try writeAllowedList(a, buf, allowed);
        },
        .unit_wrong => |w| {
            try buf.appendSlice(a, "got number with unit `");
            try buf.appendSlice(a, w.got);
            try buf.appendSlice(a, "`");
            try writeAllowedList(a, buf, w.allowed);
        },
        .unit_forbidden => |got| {
            try buf.appendSlice(a, "got number with unit `");
            try buf.appendSlice(a, got);
            try buf.appendSlice(a, "` (slot rejects units — bare number required)");
        },
        .not_member => |w| {
            try buf.appendSlice(a, "got `");
            try buf.appendSlice(a, w.got);
            try buf.appendSlice(a, "`");
            try writeAllowedMembers(a, buf, w.allowed);
        },
        .not_head_member => |w| {
            try buf.appendSlice(a, "got form head `");
            try buf.appendSlice(a, w.got);
            try buf.appendSlice(a, "`");
            try writeAllowedHeads(a, buf, w.allowed);
        },
        .unknown_element_kind => |w| try writeUnknownElementKind(a, buf, w.name, w.namespace),
        .ambiguous_element_kind => |k| try writeAmbiguousElementKind(a, buf, k.name, k.claimants),
        .recursion_depth => try buf.appendSlice(a, "value kind chain too deep"),
        .not_cross_ref => |w| {
            try buf.appendSlice(a, "got `");
            try buf.appendSlice(a, w.got);
            try buf.appendSlice(a, "` (no `(");
            try buf.appendSlice(a, w.target);
            try buf.appendSlice(a, " :name …)` form declares this name)");
        },
        .cross_ref_outside_scope => |w| {
            try buf.appendSlice(a, "got `");
            try buf.appendSlice(a, w.got);
            try buf.appendSlice(a, "` outside any enclosing `(");
            try buf.appendSlice(a, w.scope_form);
            try buf.appendSlice(a, " …)` — this cross-ref is `:scope`-bound");
        },
        .union_no_branch_matched => |u| {
            try buf.appendSlice(a, "got ");
            try buf.appendSlice(a, u.got_label);
            try buf.appendSlice(a, " (no alternative matched: ");
            for (u.alternatives, 0..) |alt, i| {
                if (i > 0) try buf.appendSlice(a, " | ");
                try buf.appendSlice(a, "`");
                if (alt.namespace) |ns| {
                    try buf.appendSlice(a, ns);
                    try buf.appendSlice(a, "/");
                }
                try buf.appendSlice(a, alt.name);
                try buf.appendSlice(a, "`");
            }
            try buf.appendSlice(a, ")");
        },
        .number_below_min => |nf| try writeNumericFail(a, buf, "below minimum", nf),
        .number_above_max => |nf| try writeNumericFail(a, buf, "above maximum", nf),
        .number_at_or_below_exclusive_min => |nf| try writeNumericFail(a, buf, "must be strictly greater than", nf),
        .number_at_or_above_exclusive_max => |nf| try writeNumericFail(a, buf, "must be strictly less than", nf),
        .number_not_integer => |v| {
            const piece = try std.fmt.allocPrint(a, "value {d} is not an integer", .{v});
            try buf.appendSlice(a, piece);
        },
        .numeric_bound_unit_mismatch => |m| {
            try buf.appendSlice(a, "value unit ");
            try writeUnitOrNone(a, buf, m.value_unit);
            try buf.appendSlice(a, " does not match bound unit ");
            try writeUnitOrNone(a, buf, m.bound_unit);
        },
        .repr_out_of_range => |r| try writeReprFail(a, buf, r),
        .string_too_short => |s| {
            const piece = try std.fmt.allocPrint(
                a,
                "string length {d} is below :min-len {d}",
                .{ s.got, s.min_len },
            );
            try buf.appendSlice(a, piece);
        },
        .string_too_long => |s| {
            const piece = try std.fmt.allocPrint(
                a,
                "string length {d} is above :max-len {d}",
                .{ s.got, s.max_len },
            );
            try buf.appendSlice(a, piece);
        },
        .string_format_mismatch => |s| {
            const piece = try std.fmt.allocPrint(
                a,
                "string \"{s}\" does not satisfy :format `{s}`",
                .{ s.got, s.format },
            );
            try buf.appendSlice(a, piece);
        },
        .string_pattern_mismatch => |s| {
            const piece = try std.fmt.allocPrint(
                a,
                "string \"{s}\" does not match :pattern `{s}`",
                .{ s.got, s.pattern },
            );
            try buf.appendSlice(a, piece);
        },
    }
}

fn describeNodeBinary(
    a: Allocator,
    buf: *std.ArrayList(u8),
    view: BinaryCursor.NodeView,
    extras: MatchExtras,
) Allocator.Error!void {
    switch (view.kind) {
        .number => try buf.appendSlice(a, "number"),
        .number_with_unit => {
            try buf.appendSlice(a, "number with unit `");
            try buf.appendSlice(a, extras.unit.?);
            try buf.appendSlice(a, "`");
        },
        .string => try buf.appendSlice(a, "string"),
        .keyword => try buf.appendSlice(a, "keyword"),
        .symbol => try buf.appendSlice(a, "symbol"),
        .boolean => try buf.appendSlice(a, "boolean"),
        .nil => try buf.appendSlice(a, "nil"),
        .date => try buf.appendSlice(a, "date"),
        .time => try buf.appendSlice(a, "time"),
        .vector => {
            const piece = try std.fmt.allocPrint(a, "vector of length {d}", .{extras.vec_len});
            try buf.appendSlice(a, piece);
        },
        .form => try buf.appendSlice(a, "form"),
    }
}
