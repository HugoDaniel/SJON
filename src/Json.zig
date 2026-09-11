//! JSON bridge — `Tree ↔ std.json.Value` mapping with two encoding modes.
//!
//! Encoding:
//!
//!   nil                 → null
//!   true / false        → true / false
//!   number (f64)        → integer / float (integer-valued numbers
//!                         within ±2^53 emit as integer; rest as float)
//!   number_i64          → integer (exact, fits std.json's i64 integer)
//!   number_u64          → integer when v ≤ i64.max; else number_string
//!                         carrying the literal digits (RFC 8259 admits
//!                         arbitrary-precision number syntax via
//!                         std.json's `.number_string` variant)
//!   number with unit    → canonical  {"$num": [<value>, "<unit>"]}
//!                         compact    bare number (unit dropped)
//!   string              → string
//!   :keyword            → canonical  {"$kw": "name"}
//!                         compact    "name"  (collides with strings —
//!                                    one-way; from-json treats every
//!                                    string as a string)
//!   symbol              → canonical  {"$sym": "name"}
//!                         compact    "name"  (same one-way collapse)
//!   date                → canonical  {"$date": "YYYY-MM-DD"}
//!                         compact    "YYYY-MM-DD"  (one-way, as above)
//!   time                → canonical  {"$time": "HH:MM:SS[.fff]"}
//!                         compact    "HH:MM:SS[.fff]"  (same one-way collapse)
//!   [a b c] vector      → [a, b, c]
//!   (form :k v c1 c2)   → {"$form":"form", "$ns":"…", "k":v,
//!                          "$children":[c1, c2]}
//!   (+ a b) safe expr   → {"$expr":["+", a, b]}  (only when a Schema
//!                          is supplied and the head matches an
//!                          expression function); qualified heads
//!                          (`(myns/foo a)`) emit a sibling `$ns`
//!                          alongside `$expr`.
//!
//! Limitations:
//!   * Tree-level operations require exactly one root node. Multi-root
//!     files raise `error.MultipleRoots`. Use `toJsonNode` / `fromJsonNode`
//!     for explicit per-node bridging.
//!   * Comments are not encoded; Binary IR is the supported channel for
//!     comment-preserving round-trip.
//!
//! Round-trip contract (canonical mode):
//!
//!   canonical-print(parse(s))
//!     ≡ canonical-print(fromJson(toJson(parse(s))))
//!
//! That is, encoding to JSON and decoding back must produce a tree whose
//! canonical print matches the original. Pinned by the per-form regression
//! test in `fixtures/json_roundtrip.sjon — every top-level form round-trips
//! canonically`. Compact mode collapses keyword/symbol/string into a single
//! string variant and is one-way: there is no `fromJson` round-trip claim
//! in compact mode.

const std = @import("std");
const Date = @import("Date.zig");
const Time = @import("Time.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Ast = @import("Ast.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const Discriminators = @import("SchemaExport/Discriminators.zig");

/// Options for `toJson` / `toJsonNode`.
pub const ToJsonOptions = struct {
    /// Encoding mode. `canonical` (default) uses deterministic tagged
    /// shapes (`{"$kw":…}`, `{"$sym":…}`, `{"$form":…}`) so JSON
    /// consumers can recover the SJON value cleanly. `compact` collapses
    /// keywords and symbols to bare strings for human-readable dumps and
    /// is one-way — the keyword/symbol/string trichotomy is lost on
    /// re-decode. `full` aliases `canonical` (JSON has no extra trivia
    /// axis to preserve).
    mode: Ast.Mode = .canonical,
    /// Optional schema. Heads that match an expression function are
    /// encoded with `$expr`; without a schema, every form uses `$form`.
    schema: ?Schema.Schema = null,

    /// Parallel to `Binary.ToBinaryOptions.forMode`. Schema stays null;
    /// override the field directly when one is needed.
    pub fn forMode(mode: Ast.Mode) ToJsonOptions {
        return .{ .mode = mode };
    }
};

/// Options for `fromJson` / `buildAstNodeIn`.
pub const FromJsonOptions = struct {
    /// Encoding mode this JSON was produced with. See `ToJsonOptions.mode`.
    mode: Ast.Mode = .canonical,

    /// Parallel to `Binary.ToBinaryOptions.forMode`.
    pub fn forMode(mode: Ast.Mode) FromJsonOptions {
        return .{ .mode = mode };
    }
};

/// Owns the arena holding the encoded `std.json.Value`. Call `deinit` to
/// release.
pub const Result = struct {
    arena: ArenaAllocator,
    value: std.json.Value,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};

/// Errors the JSON bridge can return. `MultipleRoots` is raised by
/// tree-level operations that demand exactly one root.
/// `UnknownDiscriminator` is raised when a `$`-prefixed key is not one of
/// the recognised discriminators and not a sigil-escaped (`$$…`) user key.
/// `DepthExceeded` bounds the recursive `std.json.Value → Tree` decode:
/// JSON reaching this bridge is often UNVALIDATED (the kitchen-sink wasm
/// entrypoints decode host-supplied JSON), so nesting past `MAX_JSON_DEPTH`
/// returns an error rather than blowing the native / wasm-shadow stack.
pub const Error = error{
    OutOfMemory,
    MultipleRoots,
    InvalidEncoding,
    InvalidExprForm,
    InvalidFormHead,
    UnknownDiscriminator,
    DepthExceeded,
};

/// Ceiling on JSON value nesting for the `fromJson` family, deliberately
/// equal to `Parser.MAX_PARSE_DEPTH` (1024) so the JSON bridge and the
/// source parser reject over-deep structures at the same depth. Kept as a
/// local constant (not an import) to avoid coupling the decoder to the
/// parser; the equality is a documented invariant, not a compile-time link.
pub const MAX_JSON_DEPTH: u32 = 1024;

// ---------------------------------------------------------------------------
// Reserved-key sigil escape
//
// `$`-prefixed keys collide with the bridge's discriminators. Encoder
// double-prefixes any user key starting with `$` (so `$foo` → `$$foo`);
// decoder strips one `$` back. A key that starts with `$` but is not a
// recognised discriminator and not `$$`-prefixed raises
// `error.UnknownDiscriminator`.
// ---------------------------------------------------------------------------

fn isKnownFormDiscriminator(key: []const u8) bool {
    for (Discriminators.form_keys) |d| {
        if (std.mem.eql(u8, key, d)) return true;
    }
    return false;
}

fn escapeKey(a: Allocator, key: []const u8) Error![]const u8 {
    // Always allocate into `a` so the Result is self-contained — callers
    // do not need to keep the source tree alive past `result.deinit()`.
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

// ---------------------------------------------------------------------------
// Encode: SJON → JSON
//
// `toJson`, `toJsonRoots`, `toJsonNode` walk `Ast.Tree` directly.
// ---------------------------------------------------------------------------

/// Encode a single-root `Tree` to JSON. Caller must `result.deinit()`.
/// Complexity: O(n) where n = `tree.nodes.len` (single walk via
/// `buildJson`). Allocates into the returned `Result.arena`; `tree`
/// is not modified.
pub fn toJson(gpa: Allocator, tree: Ast.Tree, opts: ToJsonOptions) Error!Result {
    if (tree.root.len != 1) return error.MultipleRoots;
    return toJsonNode(gpa, &tree, tree.root[0], opts);
}

/// Encode a multi-root `Tree` wrapped in `{"$roots": [...]}`. Caller must
/// `result.deinit()`. Complexity: O(n).
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

/// Encode a single `Tree` node (by index) to JSON. Caller must
/// `result.deinit()`. Complexity: O(k) where k = size of the subtree
/// rooted at `idx`. `tree` is borrowed read-only.
pub fn toJsonNode(
    gpa: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    opts: ToJsonOptions,
) Error!Result {
    // A kvpair has no JSON value of its own — it is a member of its
    // form's object — and `buildJson` treats the tag as unreachable.
    if (tree.tagOf(idx) == .kvpair) return error.InvalidEncoding;
    std.debug.assert(@intFromEnum(idx) < tree.nodes.len); // a real node index into this tree
    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const v = try buildJson(a, tree, idx, opts);
    return .{ .arena = arena, .value = v };
}

/// Host-stack recursion over the tree, bounded by the tree invariant
/// every producer keeps: `Parser` at `MAX_PARSE_DEPTH`, `Binary` at
/// `MAX_TREE_DEPTH`, `fromJson` at `MAX_JSON_DEPTH`, and `Edit`, which
/// measures each edited tree against `MAX_EDIT_PATH_DEPTH` — all 1024.
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
        // kvpair only appears as a form child; see formToJson.
        .kvpair => unreachable,
    };
}

fn numberToJson(x: f64) std.json.Value {
    if (!std.math.isFinite(x)) return .{ .float = x };
    // 2^53 — the f64 exact-integer ceiling (see `Printer.formatNumberInto`
    // for the twin copy). Deliberately not shared with `Expr`'s `TWO_53`
    // or `SchemaExport`'s `Model.F64_PRECISE_INT_CEILING` — each is
    // corpus-pinned to its own subsystem.
    const safe_int_max: f64 = @floatFromInt(@as(i64, 1) << 53);
    if (@floor(x) == x and @abs(x) < safe_int_max) {
        return .{ .integer = @intFromFloat(x) };
    }
    return .{ .float = x };
}

/// Tag-aware bridge from any number-shape AST node to `std.json.Value`.
/// `.number` keeps the legacy 2^53-guarded f64 emission; the integer
/// tags emit exact digits. Values in `.number_u64` above `i64.max` would
/// not fit in std.json's i64 `.integer`, so they emit as `.number_string`
/// — std.json round-trips that variant byte-for-byte through its writer.
fn treeNumberToJson(a: Allocator, tree: *const Ast.Tree, idx: Ast.NodeIndex) Error!std.json.Value {
    return switch (tree.tagOf(idx)) {
        .number => numberToJson(tree.numberOf(idx)),
        .number_i64 => .{ .integer = tree.numberI64Of(idx) },
        .number_u64 => blk: {
            const v = tree.numberU64Of(idx);
            if (v <= std.math.maxInt(i64)) {
                break :blk .{ .integer = @intCast(v) };
            }
            // SAFETY: a u64 prints in at most 20 digits.
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
            break :blk .{ .number_string = try a.dupe(u8, s) };
        },
        else => unreachable,
    };
}

/// Encode a `NumberValue`. Unit-bearing numbers in canonical mode emit a
/// `{"$num": [value, "unit"]}` discriminator object; unitless numbers and
/// compact-mode unit-bearing numbers emit a bare JSON number.
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

/// Emit an owned string either bare (`.compact`) or wrapped in a single-key
/// discriminator object `{"$tag": owned}` (`.canonical` / `.full`). The shared
/// shape behind `$kw` / `$sym` / `$date` / `$time`. `owned` must already be
/// duped into `a` — it is handed straight into the JSON value, not re-copied.
fn taggedString(a: Allocator, tag: []const u8, owned: []const u8, opts: ToJsonOptions) Error!std.json.Value {
    return switch (opts.mode) {
        .compact => .{ .string = owned },
        .canonical, .full => blk: {
            var obj: std.json.ObjectMap = .empty;
            try obj.put(a, tag, .{ .string = owned });
            break :blk .{ .object = obj };
        },
    };
}

fn keywordToJson(a: Allocator, name: []const u8, opts: ToJsonOptions) Error!std.json.Value {
    return taggedString(a, "$kw", try a.dupe(u8, name), opts);
}

fn symbolToJson(a: Allocator, name: []const u8, opts: ToJsonOptions) Error!std.json.Value {
    return taggedString(a, "$sym", try a.dupe(u8, name), opts);
}

/// Encode a `Date` as JSON. Canonical / full emit the tagged form
/// `{"$date": "YYYY-MM-DD"}` (sibling to `$num`, `$kw`, `$sym`);
/// compact emits the bare ISO 8601 string. Decoders that re-ingest the
/// compact form will see a string, not a date — `fromJson` only
/// recognises `$date` in tagged shape.
fn dateToJson(a: Allocator, d: Date, opts: ToJsonOptions) Error!std.json.Value {
    var buf: [10]u8 = undefined;
    d.formatCanonical(&buf);
    return taggedString(a, "$date", try a.dupe(u8, &buf), opts);
}

/// Encode a `Time` as JSON. Canonical / full emit the tagged form
/// `{"$time": "HH:MM:SS"}` or `{"$time": "HH:MM:SS.fff"}` (sibling to
/// `$num`, `$kw`, `$sym`, `$date`); compact emits the bare ISO 8601
/// string. Decoders that re-ingest the compact form will see a
/// string, not a time — `fromJson` only recognises `$time` in tagged
/// shape. Length is variable (8 when `millisecond == 0`, 12 otherwise)
/// so the byte-for-byte round-trip mirrors the printer.
fn timeToJson(a: Allocator, t: Time, opts: ToJsonOptions) Error!std.json.Value {
    var buf: [12]u8 = undefined;
    const n = t.formatCanonical(&buf);
    return taggedString(a, "$time", try a.dupe(u8, buf[0..n]), opts);
}

// Tree helpers — walk the SoA representation. Discriminator selection /
// sigil escape / number encoding helpers (`numberToJson`,
// `numberValueToJson`, `keywordToJson`, `symbolToJson`, `escapeKey`) are
// representation-independent and live above.

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

// ---------------------------------------------------------------------------
// Decode: JSON → SJON
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Decode: JSON → Tree
//
// `fromJson` / `fromJsonRoots` build an SoA `Ast.Tree` directly via
// `Ast.TreeBuilder`.
// ---------------------------------------------------------------------------

/// Decode a single JSON value into a single-root `Tree`. Caller must
/// `tree.deinit()`. The resulting tree has an empty `source` slice —
/// printing it produces canonical bytes rather than reproducing any
/// original text.
///
/// Complexity: O(n) where n = total JSON node count. `value` is
/// borrowed read-only — string content is duplicated into the tree's
/// arena so the caller can free the input JSON immediately after.
pub fn fromJson(gpa: Allocator, value: std.json.Value, opts: FromJsonOptions) Error!Ast.Tree {
    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var b: Ast.TreeBuilder = .{ .a = a };
    const root_idx = try buildAst(&b, value, opts);

    const roots = try a.alloc(Ast.NodeIndex, 1);
    roots[0] = root_idx;

    return b.finalizeWith(&arena, "", roots, .{});
}

/// Decode a `{"$roots": [...]}` wrapper into a multi-root `Tree`. Caller
/// must `tree.deinit()`.
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

    return b.finalizeWith(&arena, "", roots, .{});
}

// ---------------------------------------------------------------------------
// Decoder helpers — drive `Ast.TreeBuilder` from a `std.json.Value`.
// ---------------------------------------------------------------------------

const zero_span: Ast.Span = .{ .start = 0, .end = 0 };

fn buildAst(b: *Ast.TreeBuilder, value: std.json.Value, opts: FromJsonOptions) Error!Ast.NodeIndex {
    return buildAstDepth(b, value, opts, 0);
}

/// Recursive core of `buildAst`. `depth` is the nesting level of `value`
/// (root = 0); it trips `error.DepthExceeded` at `MAX_JSON_DEPTH` before
/// descending, so untrusted JSON can't exhaust the stack. The two
/// descend-into-child sites (`arrayToVector` elements and `makeFormNode`
/// children) pass `depth + 1`; the object-dispatch helpers stay at the
/// same level and thread `depth` through unchanged.
fn buildAstDepth(b: *Ast.TreeBuilder, value: std.json.Value, opts: FromJsonOptions, depth: u32) Error!Ast.NodeIndex {
    if (depth >= MAX_JSON_DEPTH) return error.DepthExceeded;
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
        .array => |arr| try arrayToVector(b, arr, opts, depth),
        .object => |obj| try objectToForm(b, obj, opts, depth),
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

/// Decode a `.number_string` payload to the most exact AST tag that
/// fits: `.number_i64` → `.number_u64` → `.number` (lossy fallback).
/// The std.json reader only produces `.number_string` when the input
/// is too large for i64 or has more digits than i64 can hold, so the
/// common landing here is `.number_u64`.
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

fn arrayToVector(b: *Ast.TreeBuilder, arr: std.json.Array, opts: FromJsonOptions, depth: u32) Error!Ast.NodeIndex {
    var elements = try std.ArrayList(Ast.NodeIndex).initCapacity(b.a, arr.items.len);
    for (arr.items) |item| {
        elements.appendAssumeCapacity(try buildAstDepth(b, item, opts, depth + 1));
    }
    return try b.addVector(elements.items, zero_span);
}

/// Extract the string body of a discriminator's payload value, or
/// `error.InvalidEncoding` when it isn't a JSON string. The shared prefix of
/// the `$kw` / `$sym` / `$date` / `$time` atom decoders (and the `$ns` /
/// `$num`-unit string reads).
fn stringPayloadOf(v: std.json.Value) Error![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => error.InvalidEncoding,
    };
}

fn objectToForm(b: *Ast.TreeBuilder, obj: std.json.ObjectMap, opts: FromJsonOptions, depth: u32) Error!Ast.NodeIndex {
    if (obj.get("$roots") != null) return error.MultipleRoots;
    if (obj.get("$expr")) |expr_v| return try exprObjectToForm(b, obj, expr_v, opts, depth);
    if (obj.get("$form")) |form_name_v| return try formObjectToForm(b, obj, form_name_v, opts, depth);
    if (obj.get("$num")) |num_v| return try numObjectToNumber(b, num_v);
    if (obj.get("$kw")) |kw_v| return try b.appendKeyword(try stringPayloadOf(kw_v), zero_span);
    if (obj.get("$sym")) |sym_v| return try b.appendSymbol(try stringPayloadOf(sym_v), zero_span);
    if (obj.get("$date")) |date_v| {
        const d = Date.parse(try stringPayloadOf(date_v)) catch return error.InvalidEncoding;
        return try b.appendDate(d, zero_span);
    }
    if (obj.get("$time")) |time_v| {
        const t = Time.parse(try stringPayloadOf(time_v)) catch return error.InvalidEncoding;
        return try b.appendTime(t, zero_span);
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
    const unit_raw = try stringPayloadOf(items[1]);
    if (unit_raw.len == 0) return error.InvalidEncoding;

    return try b.appendNumberWithUnit(value, unit_raw, zero_span);
}

fn exprObjectToForm(b: *Ast.TreeBuilder, obj: std.json.ObjectMap, expr_v: std.json.Value, opts: FromJsonOptions, depth: u32) Error!Ast.NodeIndex {
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
            const ns = try stringPayloadOf(entry.value_ptr.*);
            if (ns.len == 0) return error.InvalidEncoding;
            if (std.mem.indexOfScalar(u8, ns, '/') != null) return error.InvalidEncoding;
            namespace = ns;
            continue;
        }
        return error.UnknownDiscriminator;
    }
    return try makeFormNode(b, unescapeKey(head_raw), namespace, items[1..], &.{}, &.{}, opts, depth);
}

fn formObjectToForm(
    b: *Ast.TreeBuilder,
    obj: std.json.ObjectMap,
    form_name_v: std.json.Value,
    opts: FromJsonOptions,
    depth: u32,
) Error!Ast.NodeIndex {
    const head_raw = switch (form_name_v) {
        .string => |s| s,
        else => return error.InvalidFormHead,
    };
    const namespace: ?[]const u8 = if (obj.get("$ns")) |ns_v| try stringPayloadOf(ns_v) else null;

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

    return try makeFormNode(b, unescapeKey(head_raw), namespace, children_items, kp_keys.items, kp_values.items, opts, depth);
}

fn makeFormNode(
    b: *Ast.TreeBuilder,
    head: []const u8,
    namespace: ?[]const u8,
    positional: []const std.json.Value,
    kp_keys: []const []const u8,
    kp_values: []const std.json.Value,
    opts: FromJsonOptions,
    depth: u32,
) Error!Ast.NodeIndex {
    var children = try std.ArrayList(Ast.NodeIndex).initCapacity(b.a, positional.len + kp_keys.len);

    // Keyword pairs first (matches the legacy ordering — round-trip
    // contract is structural equality, not byte equality). A form's
    // children sit one nesting level below it, hence `depth + 1`.
    for (kp_keys, kp_values) |k, v| {
        const value_idx = try buildAstDepth(b, v, opts, depth + 1);
        const key_si = try b.addString(k);
        const kv_idx = try b.addKvpair(key_si, value_idx, zero_span, zero_span);
        children.appendAssumeCapacity(kv_idx);
    }
    for (positional) |v| {
        children.appendAssumeCapacity(try buildAstDepth(b, v, opts, depth + 1));
    }

    const head_si = try b.addString(head);
    const ns_si: ?Ast.StringIndex = if (namespace) |n| try b.addString(n) else null;
    return try b.addForm(head_si, ns_si, zero_span, children.items, zero_span);
}

test {
    _ = @import("Json_tests.zig");
}
