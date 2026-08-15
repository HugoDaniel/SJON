//! PatternQuery — the deterministic pattern→event engine.
//!
//! A *pattern* is ordinary SJON data (forms / vectors / atoms); this module
//! interprets it as a Strudel-style `query(window) -> [Hap]` function. The
//! engine is a bounded, frame-stack walker (no host-stack recursion), so a
//! pathological pattern refuses with a diagnostic or a resource error rather
//! than hanging or smashing the stack. Time is integer ticks on the shared
//! `Pattern` grid (`PPC = 720720`), randomness is SJON's seeded SplitMix64,
//! and everything is computed with checked arithmetic — the whole point is
//! that the same pattern + window + seed produces bit-identical haps in every
//! host (Zig native, wasm, the TypeScript port).
//!
//! **Dependency direction (load-bearing).** PatternQuery imports
//! `Pattern` / `Ast` / `Expr` / `Schema` / `BinaryCursor` — never the
//! reverse. `Expr` stays oblivious to patterns; PatternQuery embeds it as a
//! leaf subroutine: a form in `pure`-value position — e.g.
//! `(pure (* 0.5 (+ 1 (sin (* (tau) cycle)))))` or `(pure (rand01 seed cycle))`
//! — is an `Expr` expression of time, evaluated once per hap with `cycle`
//! (f64), `tick` (i64), and `seed` (i64) bound. Every other form is a
//! combinator and every bare atom is a literal. The expr path is **tree-only**;
//! the binary path degrades an expr leaf to `silence` (see `compileBinary`).
//!
//! **Serialization is hand-rolled.** The `(haps …)` writer below never calls
//! `Printer` and reads binary only through `BinaryCursor`, so the read-only
//! `sjon-binary.wasm` artifact can ship the pattern consumer without dragging
//! in the parser / printer / edit logic.
//!
//! The value vocabulary (`Hap` / `PatValue`), the bounded compile + query
//! walkers, the two front-ends (`compileTree` / `compileBinary` → shared
//! `Node`), the `(haps …)` serializer ↔ reconstructor round-trip, and the
//! per-hap `Expr` leaf evaluator all live here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Pattern = @import("Pattern.zig");
const Schema = @import("Schema.zig");
const Expr = @import("Expr.zig");
const BinaryCursor = @import("BinaryCursor.zig");

pub const Span = Pattern.Span;
pub const Tick = Pattern.Tick;
pub const TimedSpan = Pattern.TimedSpan;
const PPC = Pattern.PPC;

/// Resource ceilings — the four bounded axes, mirroring `Expr.zig`'s
/// (steps / frame-depth / bytes) plus a hap-count axis specific to patterns
/// (a `fast`/`seq`/`stack` count amplifier can be step-light yet hap-heavy).
/// No host-stack recursion anywhere: both compile and query are heap
/// frame-stack walkers bounded by these.
pub const MAX_QUERY_DEPTH: u32 = 256; // conceptual pattern nesting ceiling
const MAX_QUERY_FRAMES: u32 = MAX_QUERY_DEPTH * 4; // live query-frame stack
const MAX_COMPILE_FRAMES: u32 = MAX_QUERY_DEPTH * 4; // live compile-frame stack
const MAX_QUERY_STEPS: u32 = 1 << 20; // total interpreter steps per call
pub const MAX_QUERY_BYTES: usize = 1 << 26; // 64 MiB result-arena ceiling
const MAX_HAPS: usize = 1 << 16; // emitted-hap ceiling (count amplifier guard)

/// The two size-shaped ceilings a caller may lower, carried together so the
/// `*WithBudget` entries take one parameter instead of a growing row of
/// bare `usize`s. Defaults are the production values; a test lowers the axis
/// it wants to trip and leaves the other alone.
///
/// The step and frame ceilings are deliberately NOT here: those are pattern
/// *shape* limits, reachable from an ordinary input, and they already have
/// trips (`MAX_QUERY_FRAMES` at "query: depth guard").
pub const Budget = struct {
    bytes: usize = MAX_QUERY_BYTES,
    haps: usize = MAX_HAPS,
};

/// Per-hap `Expr` evaluation runs against a fixed scratch buffer (a
/// `FixedBufferAllocator`, reset before each eval — the pacer precedent), so
/// a thousand-hap query does zero per-hap heap churn and never competes with
/// the result arena / `MAX_QUERY_BYTES`. The buffer is allocated once per
/// query call. Because the allocator is a fixed buffer, *every* `Expr` error
/// — including `OutOfMemory` (scratch exhaustion) — is a deterministic
/// function of (expr, cycle, seed): the same input exhausts identically on
/// every host, so a per-hap eval failure is a clean drop, never a process
/// OOM. `PATTERN_EXPR_BYTES` is the budget handed to `Expr` (≤ the buffer).
const PATTERN_EXPR_SCRATCH: usize = 256 * 1024; // fixed scratch buffer
const PATTERN_EXPR_BYTES: usize = 256 * 1024; // Expr result-arena budget

/// Engine error set. Resource refusals are *returned* (the walker trips
/// one and unwinds), distinct from the *collected* `pattern_tick_overflow`
/// diagnostic added in a later commit:
///   * `DepthExceeded` — frame stack exceeded `MAX_QUERY_FRAMES`.
///   * `MemoryBudgetExceeded` — result arena passed the byte budget.
///   * `HapBudgetExceeded` — emitted hap count passed `MAX_HAPS`.
///   * `TickOverflow` — a checked tick op exceeded `Pattern.MAX_TICK` on a
///     path the engine cannot localize to a single offending node (the
///     localizable case becomes a diagnostic instead).
///   * `OutOfMemory` — arena allocation failed.
pub const Error = error{
    OutOfMemory,
    DepthExceeded,
    MemoryBudgetExceeded,
    HapBudgetExceeded,
    TickOverflow,
};

/// Error set for `reconstructHaps` — parsing a `(haps …)` tree back into
/// `[]Hap` for conformance comparison. `MalformedHapForm` = the tree is not
/// a well-formed `(haps (hap :part [b e] :whole [b e]? :value V) …)` shape.
pub const ReconstructError = error{ OutOfMemory, MalformedHapForm };

/// Error set for the binary front-end. Composes the engine `Error` with the
/// binary-cursor errors plus `MultipleRoots` (a binary buffer with more than
/// one root node is not a single pattern).
pub const BinaryError = Error || BinaryCursor.Error || error{MultipleRoots};

/// A hap's payload — the closed set of leaf values a pattern can carry.
///
/// A deliberate *subset-plus-symbol* of `Expr.Value`: pattern atoms like
/// `bd` / `hh` are bare **symbols**, which `Expr.Value` has no variant for,
/// while the continuous-signal / form-valued cases `Expr.Value` carries are
/// out of scope here. Keeping a pattern-local union leaves `Expr` oblivious
/// and makes a future `PatValue → Expr.Value` bridge mechanical. Slices
/// (`symbol` / `string` / `keyword`) are arena-owned by the producing
/// `Result`; do not retain them past `result.deinit()`.
pub const PatValue = union(enum) {
    symbol: []const u8,
    string: []const u8,
    keyword: []const u8,
    number: f64,
    integer_i64: i64,
    integer_u64: u64,
    boolean: bool,
    nil,

    /// Bit-exact structural equality. `number` compares by raw f64 bits
    /// (so cross-host divergence in `-0.0` / NaN payloads is caught, not
    /// smoothed over); slice variants compare bytes; tags must match.
    pub fn eql(self: PatValue, other: PatValue) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .symbol => std.mem.eql(u8, self.symbol, other.symbol),
            .string => std.mem.eql(u8, self.string, other.string),
            .keyword => std.mem.eql(u8, self.keyword, other.keyword),
            .number => @as(u64, @bitCast(self.number)) == @as(u64, @bitCast(other.number)),
            .integer_i64 => self.integer_i64 == other.integer_i64,
            .integer_u64 => self.integer_u64 == other.integer_u64,
            .boolean => self.boolean == other.boolean,
            .nil => true,
        };
    }
};

/// One discrete (or, later, continuous) event: a `timing` pair and the
/// `value` it carries. Equality is structural — the conformance harness
/// compares the actual and expected hap lists positionally on
/// `(part, whole?, value)`.
pub const Hap = struct {
    timing: TimedSpan,
    value: PatValue,

    pub fn eql(self: Hap, other: Hap) bool {
        return self.timing.eql(other.timing) and self.value.eql(other.value);
    }
};

comptime {
    // The value stack will push/pop `PatValue` per frame transition; pin
    // its footprint so stack growth stays predictable across stdlib churn.
    // Largest variant is a `[]const u8` slice (16B) plus the union tag.
    std.debug.assert(@sizeOf(PatValue) <= 24);
}

// ---------------------------------------------------------------------------
// Serializer — hand-rolled `(haps …)` text. No `Printer` dependency.
//
// Shape: `(haps (hap :part [b e] :whole [b e]? VALUE) …)`.
//   * `:part` — always present, the queried fragment.
//   * `:whole` — OMITTED when `whole == part` (the common discrete case);
//     `:whole nil` when `whole == null` (continuous sample); `:whole [b e]`
//     when the event is clipped (`whole != part`). The reconstructor inverts
//     this exactly, so the omission is information-preserving.
//   * `VALUE` — the leaf as the form's single **positional** child (last),
//     rendered in source syntax (symbol bare, string quoted, keyword `:k`,
//     number / int decimal, `true`/`false`, `nil`). Positional rather than a
//     `:value V` kvpair because SJON's greedy keyword rule promotes
//     `:value :loop` into two flags — a keyword can never be a kvpair value.
//     A positional keyword stays a `Tag.keyword` child, so every value
//     variant round-trips uniformly.
// ---------------------------------------------------------------------------

/// Serialize a query `Result` to SJON text: `(diagnostics …)` when any
/// diagnostic was collected, otherwise `(haps …)`. This is the two-shape
/// contract the conformance harness and the wasm hosts dispatch on (the
/// expected form's head selects the comparison). Arena-owned result.
pub fn resultToText(arena: Allocator, result: Result) Error![]u8 {
    if (result.diagnostics.len > 0) return serializeDiagnostics(arena, result.diagnostics);
    return serializeHaps(arena, result.haps);
}

/// Serialize a diagnostic list to `(diagnostics (diagnostic :code C :path
/// [..]) …)` text — the SJON shape `expected.sjon` uses. `:code` is the
/// bare snake_case tag; path elements are bare symbols (pattern paths are
/// combinator heads). Arena-owned result.
pub fn serializeDiagnostics(arena: Allocator, diags: []const Ast.Diagnostic) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "(diagnostics");
    for (diags) |d| {
        try buf.appendSlice(arena, " (diagnostic :code ");
        try buf.appendSlice(arena, @tagName(d.code));
        try buf.appendSlice(arena, " :path [");
        for (d.path, 0..) |p, i| {
            if (i > 0) try buf.append(arena, ' ');
            try buf.appendSlice(arena, p);
        }
        try buf.appendSlice(arena, "])");
    }
    try buf.append(arena, ')');
    return buf.toOwnedSlice(arena);
}

/// Serialize a hap list to canonical `(haps …)` text allocated in `arena`.
/// Complexity: O(total hap text). The returned slice is arena-owned.
pub fn serializeHaps(arena: Allocator, haps: []const Hap) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "(haps");
    for (haps) |h| {
        try buf.appendSlice(arena, " (hap :part ");
        try appendSpan(&buf, arena, h.timing.part);
        if (h.timing.whole) |w| {
            if (!w.eql(h.timing.part)) {
                try buf.appendSlice(arena, " :whole ");
                try appendSpan(&buf, arena, w);
            }
        } else {
            try buf.appendSlice(arena, " :whole nil");
        }
        try buf.append(arena, ' ');
        try appendPatValue(&buf, arena, h.value);
        try buf.append(arena, ')');
    }
    try buf.append(arena, ')');
    return buf.toOwnedSlice(arena);
}

fn appendSpan(buf: *std.ArrayList(u8), a: Allocator, s: Span) Error!void {
    try buf.append(a, '[');
    try appendI64(buf, a, s.begin);
    try buf.append(a, ' ');
    try appendI64(buf, a, s.end);
    try buf.append(a, ']');
}

fn appendI64(buf: *std.ArrayList(u8), a: Allocator, n: i64) Error!void {
    var tmp: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
    try buf.appendSlice(a, s);
}

fn appendPatValue(buf: *std.ArrayList(u8), a: Allocator, v: PatValue) Error!void {
    switch (v) {
        .symbol => |s| try buf.appendSlice(a, s),
        .string => |s| try appendSjonString(buf, a, s),
        .keyword => |k| {
            try buf.append(a, ':');
            try buf.appendSlice(a, k);
        },
        .number => |x| try appendNumber(buf, a, x),
        .integer_i64 => |x| try appendI64(buf, a, x),
        .integer_u64 => |x| {
            var tmp: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{x}) catch unreachable;
            try buf.appendSlice(a, s);
        },
        .boolean => |b| try buf.appendSlice(a, if (b) "true" else "false"),
        .nil => try buf.appendSlice(a, "nil"),
    }
}

/// Render an f64 leaf so it re-lexes to the same `.number` variant. A bare
/// integral float (`2`) would re-lex as `number_i64`; appending `.0` keeps
/// it a float. NaN / ±inf can't originate from a pattern leaf, but are
/// rendered defensively to keep the writer total.
fn appendNumber(buf: *std.ArrayList(u8), a: Allocator, x: f64) Error!void {
    if (std.math.isNan(x)) return buf.appendSlice(a, "nan");
    if (std.math.isInf(x)) return buf.appendSlice(a, if (x > 0) "inf" else "-inf");
    // Sized from std's own published bound rather than a guess: `{d}` on
    // an f64 renders full decimal notation, so 1e308 is 310 characters and
    // the smallest denormal is 326. The old [64]u8 made `catch unreachable`
    // a lie — `sjon eval` on `(* 1e300 1e8)` panicked outright.
    var tmp: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{x}) catch unreachable;
    try buf.appendSlice(a, s);
    if (std.mem.indexOfAny(u8, s, ".eE") == null) try buf.appendSlice(a, ".0");
}

/// Append a double-quoted SJON string body, escaping the delimiter,
/// backslash, and the common control characters. Pattern leaves are almost
/// always bare symbols, so this is exercised mainly by the round-trip test.
fn appendSjonString(buf: *std.ArrayList(u8), a: Allocator, s: []const u8) Error!void {
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\r' => try buf.appendSlice(a, "\\r"),
        '\t' => try buf.appendSlice(a, "\\t"),
        else => try buf.append(a, c),
    };
    try buf.append(a, '"');
}

// ---------------------------------------------------------------------------
// Reconstructor — `(haps …)` AST → `[]Hap`. Used by the conformance harness
// (commit 3b) to compare expected vs actual. Walks the tree directly; no
// Parser dependency in this module — the caller hands over an already-parsed
// `Tree` + the `(haps …)` root.
// ---------------------------------------------------------------------------

/// Reconstruct a hap list from a parsed `(haps …)` form. Slices in the
/// resulting `PatValue`s are duped into `arena`. Complexity: O(tree size).
pub fn reconstructHaps(
    arena: Allocator,
    tree: *const Ast.Tree,
    root: Ast.NodeIndex,
) ReconstructError![]Hap {
    if (tree.tagOf(root) != .form) return error.MalformedHapForm;
    const hdr = tree.formHeader(root);
    if (!std.mem.eql(u8, hdr.head, "haps")) return error.MalformedHapForm;

    var list: std.ArrayList(Hap) = .empty;
    for (hdr.children) |child| {
        if (tree.tagOf(child) != .form) return error.MalformedHapForm;
        try list.append(arena, try reconstructOneHap(arena, tree, child));
    }
    return list.toOwnedSlice(arena);
}

fn reconstructOneHap(arena: Allocator, tree: *const Ast.Tree, idx: Ast.NodeIndex) ReconstructError!Hap {
    const hdr = tree.formHeader(idx);
    if (!std.mem.eql(u8, hdr.head, "hap")) return error.MalformedHapForm;

    var part: ?Span = null;
    var whole_seen = false;
    var whole: ?Span = null;
    var value: ?PatValue = null;

    for (hdr.children) |child| {
        if (tree.tagOf(child) == .kvpair) {
            const kv = tree.kvpairHeader(child);
            if (std.mem.eql(u8, kv.key, "part")) {
                part = try readSpan(tree, kv.value);
            } else if (std.mem.eql(u8, kv.key, "whole")) {
                whole_seen = true;
                whole = if (tree.tagOf(kv.value) == .nil) null else try readSpan(tree, kv.value);
            } else return error.MalformedHapForm; // unknown kvpair key
        } else {
            // The value is the single positional child. A second one is a
            // malformed hap.
            if (value != null) return error.MalformedHapForm;
            value = try readPatValue(arena, tree, child);
        }
    }

    const p = part orelse return error.MalformedHapForm;
    const v = value orelse return error.MalformedHapForm;
    // Absent `:whole` ⇒ whole == part (the omission convention).
    return .{ .timing = .{ .whole = if (whole_seen) whole else p, .part = p }, .value = v };
}

fn readSpan(tree: *const Ast.Tree, idx: Ast.NodeIndex) ReconstructError!Span {
    if (tree.tagOf(idx) != .vector) return error.MalformedHapForm;
    const elems = tree.vectorElements(idx);
    if (elems.len != 2) return error.MalformedHapForm;
    const b = try readTick(tree, elems[0]);
    const e = try readTick(tree, elems[1]);
    if (b > e) return error.MalformedHapForm;
    return Span.init(b, e);
}

fn readTick(tree: *const Ast.Tree, idx: Ast.NodeIndex) ReconstructError!Tick {
    // Ticks are exact integers on the PPC grid; the serializer emits them
    // bare, so they re-lex as `number_i64` (including negatives).
    if (tree.tagOf(idx) != .number_i64) return error.MalformedHapForm;
    return tree.numberI64Of(idx);
}

fn readPatValue(arena: Allocator, tree: *const Ast.Tree, idx: Ast.NodeIndex) ReconstructError!PatValue {
    return switch (tree.tagOf(idx)) {
        .symbol => .{ .symbol = try arena.dupe(u8, tree.symbolText(idx)) },
        .string => .{ .string = try arena.dupe(u8, tree.stringText(idx)) },
        .keyword => .{ .keyword = try arena.dupe(u8, tree.keywordText(idx)) },
        .number => .{ .number = tree.numberOf(idx) },
        .number_i64 => .{ .integer_i64 = tree.numberI64Of(idx) },
        .number_u64 => .{ .integer_u64 = tree.numberU64Of(idx) },
        .boolean_true => .{ .boolean = true },
        .boolean_false => .{ .boolean = false },
        .nil => .nil,
        else => error.MalformedHapForm,
    };
}

// ---------------------------------------------------------------------------
// Compiled pattern IR (`Node`).
//
// Both front-ends (`compileTree`, and `compileBinary` in a later commit)
// decode into this shared arena tree, then the single `query` engine runs on
// it — so "tree ≡ binary" reduces to "both compilers produce the same Node".
// Recursive variants carry `[]const *const Node` (the slice breaks the type
// recursion; each child is its own arena allocation).
// ---------------------------------------------------------------------------

/// A rational time scale applied to a child pattern: child plays
/// `num/den`× as fast. `fast n` compiles to `{num=n, den=1}`; `slow n` to
/// `{num=1, den=n}`. Invariant: `num >= 1` and `den >= 1` (a non-positive
/// factor compiles to `silence`, so the back-map denominator `num` is
/// always positive). `span` is the source head span, carried so a
/// window-expansion overflow can be reported as a `pattern_tick_overflow`
/// diagnostic at the offending combinator (zeroed on the binary path when
/// spans were stripped).
pub const Scale = struct {
    num: i64,
    den: i64,
    child: *const Node,
    span: Ast.Span = .{ .start = 0, .end = 0 },
};

/// One compiled pattern node. Closed set: `silence` / `pure` / `pure_expr`
/// / `seq` / `stack` / `slowcat` / `scale`. Arena-owned (slices + the value
/// payloads).
pub const Node = union(enum) {
    /// The empty pattern — queries to no haps.
    silence,
    /// One hap per cycle carrying `value`; whole = the full cycle.
    pure: PatValue,
    /// One hap per cycle whose value is an `Expr` expression of time,
    /// evaluated per query with `cycle` / `tick` / `seed` bound. Holds the
    /// `Ast.NodeIndex` of the expression form in the *source tree* — so this
    /// variant is **tree-path only** (`compileTree`); `compileBinary` never
    /// produces it (the binary path has no `*Ast.Tree` for `Expr` to walk and
    /// degrades an expr leaf to `silence`). A per-cycle eval that errors or
    /// yields an uncoercible shape drops that hap (bumping `Result.dropped`),
    /// keeping output a clean `(haps …)`.
    pure_expr: Ast.NodeIndex,
    /// fastcat: `children` tile one cycle left-to-right, each compressed to
    /// its slot and playing its own cycle. Spelled as a `[…]` vector in
    /// source. Never empty (an empty vector compiles to `silence`).
    seq: []const *const Node,
    /// Layering: every child is queried over the same span; haps concatenate
    /// in child order. Never empty (an empty stack compiles to `silence`).
    stack: []const *const Node,
    /// slowcat (`cat`): one child per cycle, round-robin — child `c mod N`
    /// plays its own cycle `floor(c/N)` during global cycle `c`. Never empty
    /// (an empty slowcat compiles to `silence`).
    slowcat: []const *const Node,
    /// Time scaling (`fast` / `slow`).
    scale: Scale,

    /// Structural equality — used by the tree ≡ binary property test (a
    /// later commit). Recurses through children.
    pub fn eql(self: *const Node, other: *const Node) bool {
        if (std.meta.activeTag(self.*) != std.meta.activeTag(other.*)) return false;
        return switch (self.*) {
            .silence => true,
            .pure => self.pure.eql(other.pure),
            .pure_expr => self.pure_expr == other.pure_expr,
            .seq => eqlChildren(self.seq, other.seq),
            .stack => eqlChildren(self.stack, other.stack),
            .slowcat => eqlChildren(self.slowcat, other.slowcat),
            .scale => self.scale.num == other.scale.num and
                self.scale.den == other.scale.den and
                self.scale.child.eql(other.scale.child),
        };
    }
};

fn eqlChildren(a: []const *const Node, b: []const *const Node) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.eql(y)) return false;
    }
    return true;
}

/// Query result — collection-over-abort, mirroring `Validator.Result`. The
/// arena owns the `haps` slice, every hap value payload, and the compiled
/// `Node` tree. `pattern_tick_overflow` lands in `diagnostics`; resource
/// refusals are returned as `Error` instead. `result.deinit()` frees
/// everything.
///
/// `dropped` counts per-hap `pure_expr` evaluations that failed at a *later*
/// cycle (eval error or uncoercible result) and so were silently omitted —
/// a domain hole, not a document defect. It is a non-diagnostic side channel
/// a host/editor can surface softly; it is **not** serialized into the
/// `(haps …)` wire text, so the dropped-hap set is pinned by the haps alone
/// (deterministic cross-host). Static defects, caught by the compile-time
/// dry-run, become diagnostics instead and never reach this counter.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    haps: []const Hap,
    diagnostics: []const Ast.Diagnostic,
    dropped: usize = 0,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};

// ---------------------------------------------------------------------------
// Compile — AST → Node. Iterative (no host recursion): a single `enter` work
// item visits an AST node and writes the compiled `*Node` to `dest`. A parent
// creates its node up front and pushes child `enter`s pointing into the node's
// own child storage, so there is no separate assemble step.
// ---------------------------------------------------------------------------

const CompileFrame = struct { idx: Ast.NodeIndex, dest: **const Node };

/// Compile the AST subtree at `root` into a `Node` allocated in `arena`.
/// `gpa` backs the transient work stack (freed before return). `schema` backs
/// the compile-time dry-run of `pure`-form expression leaves (it must carry
/// `core`, else `sin`/`+`/`rand01` resolve to form literals); combinator
/// dispatch is still by head text. `outer_env` (nullable, caller-owned, must
/// outlive the call) is chained as the PARENT of every leaf dry-run's env —
/// the pattern-locals `cycle`/`tick`/`seed` shadow it — so a host-bound name
/// like a transport clock passes the static check; see `queryTreeWithEnv`.
/// Malformed sub-patterns — and statically broken expression leaves — degrade
/// to `silence` and push a diagnostic into `diags` rather than aborting.
pub fn compileTree(
    arena: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    root: Ast.NodeIndex,
    schema: Schema.Schema,
    outer_env: ?*const Expr.Env,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!*const Node {
    var result: *const Node = undefined;
    var stack: std.ArrayList(CompileFrame) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .idx = root, .dest = &result });

    var steps: usize = 0;
    while (stack.pop()) |f| {
        steps += 1;
        if (steps > MAX_QUERY_STEPS) return error.DepthExceeded;
        if (stack.items.len > MAX_COMPILE_FRAMES) return error.DepthExceeded;
        try compileEnter(arena, gpa, tree, f.idx, f.dest, schema, outer_env, diags, &stack);
    }
    return result;
}

fn compileEnter(
    arena: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    dest: **const Node,
    schema: Schema.Schema,
    outer_env: ?*const Expr.Env,
    diags: *std.ArrayList(Ast.Diagnostic),
    stack: *std.ArrayList(CompileFrame),
) Error!void {
    switch (tree.tagOf(idx)) {
        .form => try compileForm(arena, gpa, tree, idx, dest, schema, outer_env, diags, stack),
        // `[…]` vector → fastcat seq (empty → silence).
        .vector => try compileChildSeq(arena, gpa, tree.vectorElements(idx), .seq, dest, stack),
        // Bare atom → implicit `pure` of that value.
        else => {
            if (try compileValue(arena, tree, idx)) |v| {
                dest.* = try makeNode(arena, .{ .pure = v });
            } else {
                // Non-leaf atom (date / time / unit number) — unsupported as a
                // pattern leaf this slice; degrade to silence.
                dest.* = try makeNode(arena, .silence);
            }
        },
    }
}

const ChildSeqKind = enum { seq, stack, slowcat };

fn childSeqNode(kind: ChildSeqKind, children: []const *const Node) Node {
    return switch (kind) {
        .seq => .{ .seq = children },
        .stack => .{ .stack = children },
        .slowcat => .{ .slowcat = children },
    };
}

/// Compile a sequence of child AST nodes into a `seq`/`stack`/`slowcat` node,
/// creating the node up front and pushing one `enter` per child into its
/// child slice. Empty → `silence`.
fn compileChildSeq(
    arena: Allocator,
    gpa: Allocator,
    elems: []const Ast.NodeIndex,
    kind: ChildSeqKind,
    dest: **const Node,
    stack: *std.ArrayList(CompileFrame),
) Error!void {
    if (elems.len == 0) {
        dest.* = try makeNode(arena, .silence);
        return;
    }
    const children = try arena.alloc(*const Node, elems.len);
    const node = try arena.create(Node);
    node.* = childSeqNode(kind, children);
    dest.* = node;
    // Each child fills its own slot directly; order of pushing is irrelevant.
    for (elems, 0..) |elem, i| {
        try stack.append(gpa, .{ .idx = elem, .dest = &children[i] });
    }
}

fn compileForm(
    arena: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    dest: **const Node,
    schema: Schema.Schema,
    outer_env: ?*const Expr.Env,
    diags: *std.ArrayList(Ast.Diagnostic),
    stack: *std.ArrayList(CompileFrame),
) Error!void {
    const hdr = tree.formHeader(idx);
    const positionals = countPositionals(tree, hdr.children);

    if (std.mem.eql(u8, hdr.head, "silence")) {
        dest.* = try makeNode(arena, .silence);
    } else if (std.mem.eql(u8, hdr.head, "pure")) {
        // (pure v) — exactly one positional value.
        if (positionals != 1) {
            try diags.append(arena, try arityDiag(arena, hdr, "pure expects exactly one value"));
            dest.* = try makeNode(arena, .silence);
            return;
        }
        const child = nthPositional(tree, hdr.children, 0).?;
        if (tree.tagOf(child) == .form) {
            // A form in pure-value position is an `Expr` expression of time,
            // not a literal atom. Dry-run it at cycle 0 / seed 0 (static
            // validity is seed-independent, so cycle 0 catches the whole
            // document-defect class). On success route to `pure_expr`; a
            // static failure becomes a diagnostic and the leaf degrades to
            // `silence`. Routing is narrow — only pure's direct child is read
            // as an expression, so a combinator typo elsewhere still degrades
            // to silence and keeps its `unknown_form`.
            switch (try dryRunLeaf(arena, gpa, tree, child, schema, outer_env)) {
                .value => dest.* = try makeNode(arena, .{ .pure_expr = child }),
                .eval_failed => |err| {
                    const msg = try std.fmt.allocPrint(arena, "(pure …) expression failed to evaluate at cycle 0: {s}", .{@errorName(err)});
                    try diags.append(arena, try exprLeafDiag(arena, hdr, .pattern_value_eval_failed, msg));
                    dest.* = try makeNode(arena, .silence);
                },
                .result_invalid => {
                    try diags.append(arena, try exprLeafDiag(arena, hdr, .pattern_value_result_invalid, "(pure …) expression must yield a number / string / keyword / boolean / nil (a form result usually means a misspelled function name)"));
                    dest.* = try makeNode(arena, .silence);
                },
            }
        } else if (try compileValue(arena, tree, child)) |v| {
            dest.* = try makeNode(arena, .{ .pure = v });
        } else {
            dest.* = try makeNode(arena, .silence);
        }
    } else if (std.mem.eql(u8, hdr.head, "fast") or std.mem.eql(u8, hdr.head, "slow")) {
        try compileScale(arena, gpa, tree, hdr, positionals, dest, diags, stack);
    } else if (std.mem.eql(u8, hdr.head, "stack")) {
        // (stack a b …) — every positional is a layered child.
        try compilePositionalSeq(arena, gpa, tree, hdr.children, positionals, .stack, dest, stack);
    } else if (std.mem.eql(u8, hdr.head, "euclid")) {
        try compileEuclid(arena, gpa, tree, hdr, positionals, dest, diags, stack);
    } else if (std.mem.eql(u8, hdr.head, "slowcat") or std.mem.eql(u8, hdr.head, "cat")) {
        // (slowcat a b …) / (cat a b …) — one child per cycle, round-robin.
        try compilePositionalSeq(arena, gpa, tree, hdr.children, positionals, .slowcat, dest, stack);
    } else {
        // Unknown / non-pattern head — the validator already emitted
        // `unknown_form`; degrade to silence so the walk stays well-formed.
        dest.* = try makeNode(arena, .silence);
    }
}

/// Compile `(fast N child)` / `(slow N child)` into a `scale` node. Factor is
/// an integer literal this slice (rational decomposition is deferred). A
/// non-positive or non-integer factor degrades to `silence`; wrong arity
/// emits `arity_mismatch`.
fn compileScale(
    arena: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    positionals: usize,
    dest: **const Node,
    diags: *std.ArrayList(Ast.Diagnostic),
    stack: *std.ArrayList(CompileFrame),
) Error!void {
    const is_fast = std.mem.eql(u8, hdr.head, "fast");
    if (positionals != 2) {
        try diags.append(arena, try arityDiag(arena, hdr, if (is_fast) "fast expects a factor and a pattern" else "slow expects a factor and a pattern"));
        dest.* = try makeNode(arena, .silence);
        return;
    }
    const factor_idx = nthPositional(tree, hdr.children, 0).?;
    const child_idx = nthPositional(tree, hdr.children, 1).?;

    // Integer factor only; non-positive / non-integer → silence.
    if (tree.tagOf(factor_idx) != .number_i64) {
        dest.* = try makeNode(arena, .silence);
        return;
    }
    const factor = tree.numberI64Of(factor_idx);
    if (factor <= 0) {
        dest.* = try makeNode(arena, .silence);
        return;
    }

    const node = try arena.create(Node);
    node.* = .{ .scale = .{
        .num = if (is_fast) factor else 1,
        .den = if (is_fast) 1 else factor,
        .child = undefined,
        .span = hdr.head_span,
    } };
    dest.* = node;
    try stack.append(gpa, .{ .idx = child_idx, .dest = &node.scale.child });
}

/// Bjorklund's algorithm: distribute `n` pulses over `k` steps as evenly
/// as possible (Toussaint's Euclidean rhythms). Returns an arena-owned
/// `k`-slot onset bitmap, always starting on a pulse — E(3,8) = x..x..x.
/// (tresillo), E(5,8) = x.xx.xx. (cinquillo). Iterative sequence pairing,
/// no host recursion: at every round all sequences on each side are
/// identical, so each side is one (pattern, count) pair and a round is a
/// single concatenation. `gpa` backs the transient pattern buffers.
/// Precondition: `1 <= n <= k` (the callers' domain gate).
fn bjorklund(gpa: Allocator, arena: Allocator, n: usize, k: usize) Allocator.Error![]const bool {
    std.debug.assert(n >= 1);
    std.debug.assert(n <= k);
    var pat_a: std.ArrayList(bool) = .empty;
    defer pat_a.deinit(gpa);
    var pat_b: std.ArrayList(bool) = .empty;
    defer pat_b.deinit(gpa);
    try pat_a.append(gpa, true);
    try pat_b.append(gpa, false);
    var count_a: usize = n;
    var count_b: usize = k - n;

    while (count_b > 1) {
        const pairs = @min(count_a, count_b);
        const leftover_a = count_a - pairs;
        const old_a_len = pat_a.items.len;
        try pat_a.appendSlice(gpa, pat_b.items);
        if (leftover_a > 0) {
            // b exhausted — the surplus a's (old pattern) become the remainder.
            pat_b.clearRetainingCapacity();
            try pat_b.appendSlice(gpa, pat_a.items[0..old_a_len]);
            count_b = leftover_a;
        } else {
            // a exhausted (or equal) — the surplus b's stay the remainder.
            count_b -= pairs;
        }
        count_a = pairs;
    }

    const out = try arena.alloc(bool, k);
    var w: usize = 0;
    for (0..count_a) |_| {
        @memcpy(out[w..][0..pat_a.items.len], pat_a.items);
        w += pat_a.items.len;
    }
    for (0..count_b) |_| {
        @memcpy(out[w..][0..pat_b.items.len], pat_b.items);
        w += pat_b.items.len;
    }
    std.debug.assert(w == k);
    return out;
}

/// Compile `(euclid n k child)` — the child pattern at the `n` Bjorklund
/// onsets of `k` steps, silence elsewhere — into a `seq` of k slots: a
/// pure desugar into the existing IR (Tidal's `fastcat . map (bool
/// silence p) . bjorklund`), so slot timing, budgets, and overflow
/// behavior are exactly fastcat's. `n`/`k` are integer literals; a
/// non-integer degrades to `silence` (the `fast`/`slow` discipline), as
/// does the out-of-domain `k < 1` / `n > k` — and `n < 1`, where silence
/// is simply the correct empty rhythm. Wrong arity emits
/// `arity_mismatch`. The child is compiled once per onset (each slot
/// owns its node); resource ceilings bound pathological n/k.
fn compileEuclid(
    arena: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    positionals: usize,
    dest: **const Node,
    diags: *std.ArrayList(Ast.Diagnostic),
    stack: *std.ArrayList(CompileFrame),
) Error!void {
    if (positionals != 3) {
        try diags.append(arena, try arityDiag(arena, hdr, "euclid expects pulses, steps, and a pattern"));
        dest.* = try makeNode(arena, .silence);
        return;
    }
    const n_idx = nthPositional(tree, hdr.children, 0).?;
    const k_idx = nthPositional(tree, hdr.children, 1).?;
    const child_idx = nthPositional(tree, hdr.children, 2).?;
    if (tree.tagOf(n_idx) != .number_i64 or tree.tagOf(k_idx) != .number_i64) {
        dest.* = try makeNode(arena, .silence);
        return;
    }
    const n = tree.numberI64Of(n_idx);
    const k = tree.numberI64Of(k_idx);
    if (k < 1 or n < 1 or n > k) {
        dest.* = try makeNode(arena, .silence);
        return;
    }

    const onsets = try bjorklund(gpa, arena, @intCast(n), @intCast(k));
    const slots = try arena.alloc(*const Node, @intCast(k));
    const rest = try makeNode(arena, .silence);
    dest.* = try makeNode(arena, .{ .seq = slots });
    for (onsets, 0..) |on, i| {
        if (on) {
            try stack.append(gpa, .{ .idx = child_idx, .dest = &slots[i] });
        } else {
            slots[i] = rest;
        }
    }
}

/// Like `compileChildSeq` but over a form's positional children (filtering
/// out kvpairs).
fn compilePositionalSeq(
    arena: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    children: []const Ast.NodeIndex,
    positionals: usize,
    kind: ChildSeqKind,
    dest: **const Node,
    stack: *std.ArrayList(CompileFrame),
) Error!void {
    if (positionals == 0) {
        dest.* = try makeNode(arena, .silence);
        return;
    }
    const slots = try arena.alloc(*const Node, positionals);
    const node = try arena.create(Node);
    node.* = childSeqNode(kind, slots);
    dest.* = node;
    var i: usize = 0;
    for (children) |c| {
        if (tree.tagOf(c) == .kvpair) continue;
        try stack.append(gpa, .{ .idx = c, .dest = &slots[i] });
        i += 1;
    }
    std.debug.assert(i == positionals);
}

fn makeNode(arena: Allocator, value: Node) Error!*const Node {
    const node = try arena.create(Node);
    node.* = value;
    return node;
}

/// Count positional (non-kvpair) children of a form.
fn countPositionals(tree: *const Ast.Tree, children: []const Ast.NodeIndex) usize {
    var n: usize = 0;
    for (children) |c| {
        if (tree.tagOf(c) != .kvpair) n += 1;
    }
    return n;
}

/// The `n`-th positional (non-kvpair) child of a form, or null.
fn nthPositional(tree: *const Ast.Tree, children: []const Ast.NodeIndex, n: usize) ?Ast.NodeIndex {
    var seen: usize = 0;
    for (children) |c| {
        if (tree.tagOf(c) == .kvpair) continue;
        if (seen == n) return c;
        seen += 1;
    }
    return null;
}

/// Read an AST atom as a `PatValue`, duping slices into `arena`. Returns
/// `null` for non-leaf shapes (vector / form / date / time / unit number /
/// kvpair) that cannot be a pattern leaf value.
fn compileValue(arena: Allocator, tree: *const Ast.Tree, idx: Ast.NodeIndex) Error!?PatValue {
    return switch (tree.tagOf(idx)) {
        .symbol => .{ .symbol = try arena.dupe(u8, tree.symbolText(idx)) },
        .string => .{ .string = try arena.dupe(u8, tree.stringText(idx)) },
        .keyword => .{ .keyword = try arena.dupe(u8, tree.keywordText(idx)) },
        .number => .{ .number = tree.numberOf(idx) },
        .number_i64 => .{ .integer_i64 = tree.numberI64Of(idx) },
        .number_u64 => .{ .integer_u64 = tree.numberU64Of(idx) },
        .boolean_true => .{ .boolean = true },
        .boolean_false => .{ .boolean = false },
        .nil => .nil,
        else => null,
    };
}

/// Bridge an `Expr.Value` (a per-hap eval result) into a `PatValue`, duping
/// slices into `arena` — the query *result* arena, never the eval scratch, so
/// the value outlives `result.deinit()`. Returns `null` for a shape a hap
/// cannot carry: `form` (a misspelled / unresolved head evaluates to a form
/// literal, not an error — see Expr's form-construction semantics), `vector`,
/// `date`, `time`. The caller treats `null` as uncoercible — a runtime drop,
/// or a `pattern_value_result_invalid` diagnostic at the compile dry-run.
/// `Expr.Value` has no `symbol` variant, so there is no symbol case (a pattern
/// atom is a symbol, but an expression never yields one). `OutOfMemory` from
/// the dupe is a genuine host failure and propagates.
fn fromExprValue(arena: Allocator, v: Expr.Value) Error!?PatValue {
    return switch (v) {
        .number => |x| .{ .number = x },
        .integer_i64 => |x| .{ .integer_i64 = x },
        .integer_u64 => |x| .{ .integer_u64 = x },
        .boolean => |b| .{ .boolean = b },
        .nil => .nil,
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .keyword => |k| .{ .keyword = try arena.dupe(u8, k) },
        .vector, .form, .date, .time => null,
    };
}

// ---------------------------------------------------------------------------
// Compile — Binary IR → Node, via `BinaryCursor` (the read-only artifact's
// reader; never the write-side `Binary` / `fromBinary`). The cursor is
// single-pass and monotonic: each node's bytes are fully consumed before the
// next, so a frame pushed mid-iteration runs to completion and the parent
// resumes with the cursor at the next child. Same iterative discipline as
// `Expr.evalBinary`. Produces the *same* `Node` as `compileTree` for any
// well-formed pattern → tree ≡ binary.
//
// Leniency note: binary compile degrades malformed patterns (bad arity,
// non-integer / non-positive factor) to `silence` *without* emitting the
// `arity_mismatch` the tree path collects, and `fast`/`slow` take the first
// two positionals (ignoring extras). The conformance corpus is well-formed
// and routes arity through the tree path, so the two compilers agree on every
// gated input; the asymmetry only shows for malformed binary buffers.
//
// Expr leaves are tree-path only: a form in `(pure …)` value position is a
// time *expression*, but `Expr` needs an `*Ast.Tree` to walk and this path
// has none (a `BinaryCursor`→`Ast` materializer would be a second feature).
// So the binary path deliberately degrades a `(pure <form>)` leaf to
// `silence` (where the tree path produces `pure_expr`) — no `Node.pure_expr`
// is ever emitted here. This is the one intentional tree/binary divergence;
// it is locked by a dedicated test, and the literal-atom `tree ≡ binary`
// property test excludes expression patterns. Re-uniting the paths would mean
// teaching the read-only artifact to materialize a tree, which is out of
// scope for this slice.
// ---------------------------------------------------------------------------

const BinFrame = union(enum) {
    /// Decode the node at the cursor (payload position == `view`) into `dest`.
    decode: struct { view: BinaryCursor.NodeView, dest: **const Node },
    /// Fill `slots[next..]` of a vector→`seq` from `iter` (all positional).
    vec_walk: struct { iter: BinaryCursor.VectorIter, slots: []*const Node, next: usize },
    /// Collect a form's positional children into `slots` (skipping kvpairs);
    /// on exhaustion create the `kind` node (or `silence` when empty).
    pos_walk: struct {
        iter: BinaryCursor.ChildIter,
        slots: []*const Node,
        count: usize,
        kind: ChildSeqKind,
        dest: **const Node,
    },
    /// Drain (skip) a form's remaining children — used after a `scale`'s
    /// pattern child is decoded.
    drain: struct { iter: BinaryCursor.ChildIter },
    /// After a euclid child decode into `slots[0]` (always an onset —
    /// bjorklund starts on a pulse): fan that node out to every other
    /// onset slot. The binary cursor is a forward stream and cannot
    /// re-decode the child, so the binary path SHARES one child node
    /// where the tree path compiles one per onset — `Node.eql` is
    /// structural, so tree ≡ binary still holds.
    euclid_fill: struct { slots: []*const Node, onsets: []const bool },
};

/// Compile a binary-IR pattern buffer into a `Node` in `arena`. `gpa` backs
/// the transient work stack. A buffer with ≠1 root: 0 → `silence`, >1 →
/// `MultipleRoots`. `schema`/`diags` accepted for signature parity with the
/// tree front-end; this slice emits no binary-compile diagnostics.
pub fn compileBinary(
    arena: Allocator,
    gpa: Allocator,
    bytes: []const u8,
    schema: Schema.Schema,
    diags: *std.ArrayList(Ast.Diagnostic),
) BinaryError!*const Node {
    _ = schema;
    _ = diags;
    var cursor = try BinaryCursor.Cursor.init(bytes);
    var roots = try cursor.rootIter();
    if (roots.remaining == 0) return makeNode(arena, .silence);
    if (roots.remaining > 1) return error.MultipleRoots;
    const root_view = (try roots.next()).?;

    var result: *const Node = undefined;
    var stack: std.ArrayList(BinFrame) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .decode = .{ .view = root_view, .dest = &result } });

    var steps: usize = 0;
    while (stack.pop()) |f| {
        steps += 1;
        if (steps > MAX_QUERY_STEPS) return error.DepthExceeded;
        if (stack.items.len > MAX_COMPILE_FRAMES) return error.DepthExceeded;
        switch (f) {
            .decode => |d| try binDecode(arena, gpa, &cursor, d.view, d.dest, &stack),
            .vec_walk => |w| try binVecWalk(arena, gpa, &cursor, w.iter, w.slots, w.next, &stack),
            .pos_walk => |w| try binPosWalk(arena, gpa, &cursor, w, &stack),
            .drain => |w| try binDrain(&cursor, w.iter),
            .euclid_fill => |w| {
                const child = w.slots[0];
                for (w.onsets, 0..) |on, i| {
                    if (on) w.slots[i] = child;
                }
            },
        }
    }
    return result;
}

fn binDecode(
    arena: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    view: BinaryCursor.NodeView,
    dest: **const Node,
    stack: *std.ArrayList(BinFrame),
) BinaryError!void {
    switch (view.kind) {
        .form => try binDecodeForm(arena, gpa, cursor, view, dest, stack),
        .vector => {
            const iter = try BinaryCursor.readVector(cursor, view);
            if (iter.remaining == 0) {
                dest.* = try makeNode(arena, .silence);
                return;
            }
            const slots = try arena.alloc(*const Node, iter.remaining);
            dest.* = try makeNode(arena, .{ .seq = slots });
            try stack.append(gpa, .{ .vec_walk = .{ .iter = iter, .slots = slots, .next = 0 } });
        },
        else => {
            // Leaf → implicit pure (binLeafValue always consumes the node).
            dest.* = if (try binLeafValue(arena, cursor, view)) |v|
                try makeNode(arena, .{ .pure = v })
            else
                try makeNode(arena, .silence);
        },
    }
}

fn binDecodeForm(
    arena: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    view: BinaryCursor.NodeView,
    dest: **const Node,
    stack: *std.ArrayList(BinFrame),
) BinaryError!void {
    const fv = try BinaryCursor.readForm(cursor, view);
    var iter = fv.children;
    const head = fv.head;

    if (std.mem.eql(u8, head, "silence")) {
        try binDrain(cursor, iter);
        dest.* = try makeNode(arena, .silence);
    } else if (std.mem.eql(u8, head, "pure")) {
        // Exactly one positional leaf → pure; else silence (matches the tree
        // path's arity handling, minus the diagnostic). A *form* in value
        // position is a tree-path expression: `binLeafValue` returns null for
        // it (as for any non-leaf shape), so it falls through to `silence`
        // here — the deliberate binary↔tree divergence (the tree path would
        // emit `pure_expr`). See the section header note; locked by the
        // "binary path: a (pure <expr>) leaf degrades to silence" test.
        var positional_count: usize = 0;
        var val: ?PatValue = null;
        while (try iter.next()) |entry| {
            if (entry.kind == .positional) {
                positional_count += 1;
                if (positional_count == 1) {
                    val = try binLeafValue(arena, cursor, entry.value);
                } else {
                    try BinaryCursor.skipBody(cursor, entry.value);
                }
            } else {
                try BinaryCursor.skipBody(cursor, entry.value);
            }
        }
        dest.* = if (positional_count == 1 and val != null)
            try makeNode(arena, .{ .pure = val.? })
        else
            try makeNode(arena, .silence);
    } else if (std.mem.eql(u8, head, "fast") or std.mem.eql(u8, head, "slow")) {
        try binDecodeScale(arena, gpa, cursor, head, fv.head_span, &iter, dest, stack);
    } else if (std.mem.eql(u8, head, "stack")) {
        const slots = try arena.alloc(*const Node, iter.remaining);
        try stack.append(gpa, .{ .pos_walk = .{ .iter = iter, .slots = slots, .count = 0, .kind = .stack, .dest = dest } });
    } else if (std.mem.eql(u8, head, "euclid")) {
        try binDecodeEuclid(arena, gpa, cursor, &iter, dest, stack);
    } else if (std.mem.eql(u8, head, "slowcat") or std.mem.eql(u8, head, "cat")) {
        const slots = try arena.alloc(*const Node, iter.remaining);
        try stack.append(gpa, .{ .pos_walk = .{ .iter = iter, .slots = slots, .count = 0, .kind = .slowcat, .dest = dest } });
    } else {
        try binDrain(cursor, iter);
        dest.* = try makeNode(arena, .silence);
    }
}

/// `(fast n pat)` / `(slow n pat)`: read the first positional as an integer
/// factor, decode the second positional as the child pattern, drain the rest.
/// Bad factor or a missing pattern child degrades to `silence`.
fn binDecodeScale(
    arena: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    head: []const u8,
    head_span: ?Ast.Span,
    iter: *BinaryCursor.ChildIter,
    dest: **const Node,
    stack: *std.ArrayList(BinFrame),
) BinaryError!void {
    // First positional → factor.
    var factor: ?i64 = null;
    while (try iter.next()) |entry| {
        if (entry.kind == .positional) {
            if (entry.value.kind == .number and entry.value.tag == .number_i64) {
                factor = try BinaryCursor.readNumberI64(cursor, entry.value);
            } else {
                try BinaryCursor.skipBody(cursor, entry.value);
            }
            break;
        }
        try BinaryCursor.skipBody(cursor, entry.value);
    }
    const f = factor orelse {
        try binDrain(cursor, iter.*);
        dest.* = try makeNode(arena, .silence);
        return;
    };
    if (f <= 0) {
        try binDrain(cursor, iter.*);
        dest.* = try makeNode(arena, .silence);
        return;
    }

    // Second positional → child pattern.
    var child_view: ?BinaryCursor.NodeView = null;
    while (try iter.next()) |entry| {
        if (entry.kind == .positional) {
            child_view = entry.value;
            break;
        }
        try BinaryCursor.skipBody(cursor, entry.value);
    }
    const cv = child_view orelse {
        dest.* = try makeNode(arena, .silence);
        return;
    };

    const is_fast = std.mem.eql(u8, head, "fast");
    const node = try arena.create(Node);
    node.* = .{ .scale = .{
        .num = if (is_fast) f else 1,
        .den = if (is_fast) 1 else f,
        .child = undefined,
        .span = head_span orelse .{ .start = 0, .end = 0 },
    } };
    dest.* = node;
    // Decode the child, then drain any trailing positionals/kvpairs.
    try stack.append(gpa, .{ .drain = .{ .iter = iter.* } });
    try stack.append(gpa, .{ .decode = .{ .view = cv, .dest = &node.scale.child } });
}

/// `(euclid n k pat)`: read the first two positionals as integer pulses /
/// steps, decode the third as the child pattern, drain the rest. Same
/// domain gate as the tree path (`compileEuclid`) — a non-integer or
/// out-of-domain argument, or a missing child, degrades to `silence`.
/// The child decodes ONCE into onset slot 0 and an `euclid_fill` frame
/// fans the node out to the remaining onset slots (see that variant's
/// doc for why the binary path shares where the tree path duplicates).
fn binDecodeEuclid(
    arena: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    iter: *BinaryCursor.ChildIter,
    dest: **const Node,
    stack: *std.ArrayList(BinFrame),
) BinaryError!void {
    // First two positionals → pulses, steps.
    var nums: [2]?i64 = .{ null, null };
    var got: usize = 0;
    while (got < 2) {
        const entry = (try iter.next()) orelse break;
        if (entry.kind == .positional) {
            if (entry.value.kind == .number and entry.value.tag == .number_i64) {
                nums[got] = try BinaryCursor.readNumberI64(cursor, entry.value);
            } else {
                try BinaryCursor.skipBody(cursor, entry.value);
            }
            got += 1;
        } else {
            try BinaryCursor.skipBody(cursor, entry.value);
        }
    }
    const n = nums[0] orelse {
        try binDrain(cursor, iter.*);
        dest.* = try makeNode(arena, .silence);
        return;
    };
    const k = nums[1] orelse {
        try binDrain(cursor, iter.*);
        dest.* = try makeNode(arena, .silence);
        return;
    };
    if (k < 1 or n < 1 or n > k) {
        try binDrain(cursor, iter.*);
        dest.* = try makeNode(arena, .silence);
        return;
    }

    // Third positional → child pattern.
    var child_view: ?BinaryCursor.NodeView = null;
    while (try iter.next()) |entry| {
        if (entry.kind == .positional) {
            child_view = entry.value;
            break;
        }
        try BinaryCursor.skipBody(cursor, entry.value);
    }
    const cv = child_view orelse {
        dest.* = try makeNode(arena, .silence);
        return;
    };

    const steps: usize = @intCast(k);
    const onsets = try bjorklund(gpa, arena, @intCast(n), steps);
    std.debug.assert(onsets[0]); // bjorklund always starts on a pulse
    const slots = try arena.alloc(*const Node, steps);
    const rest = try makeNode(arena, .silence);
    for (onsets, 0..) |on, i| {
        if (!on) slots[i] = rest;
    }
    dest.* = try makeNode(arena, .{ .seq = slots });
    // LIFO: decode the child into slot 0, fan it out, then drain trailing
    // children.
    try stack.append(gpa, .{ .drain = .{ .iter = iter.* } });
    try stack.append(gpa, .{ .euclid_fill = .{ .slots = slots, .onsets = onsets } });
    try stack.append(gpa, .{ .decode = .{ .view = cv, .dest = &slots[0] } });
}

fn binVecWalk(
    arena: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    iter: BinaryCursor.VectorIter,
    slots: []*const Node,
    next: usize,
    stack: *std.ArrayList(BinFrame),
) BinaryError!void {
    _ = arena;
    _ = cursor;
    var it = iter;
    const view = (try it.next()) orelse return; // node already built with slots
    try stack.append(gpa, .{ .vec_walk = .{ .iter = it, .slots = slots, .next = next + 1 } });
    try stack.append(gpa, .{ .decode = .{ .view = view, .dest = &slots[next] } });
}

fn binPosWalk(
    arena: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    w: @FieldType(BinFrame, "pos_walk"),
    stack: *std.ArrayList(BinFrame),
) BinaryError!void {
    var it = w.iter;
    while (try it.next()) |entry| {
        if (entry.kind == .positional) {
            try stack.append(gpa, .{ .pos_walk = .{ .iter = it, .slots = w.slots, .count = w.count + 1, .kind = w.kind, .dest = w.dest } });
            try stack.append(gpa, .{ .decode = .{ .view = entry.value, .dest = &w.slots[w.count] } });
            return;
        }
        try BinaryCursor.skipBody(cursor, entry.value); // skip kvpair value
    }
    // Exhausted — finalize.
    w.dest.* = if (w.count == 0)
        try makeNode(arena, .silence)
    else
        try makeNode(arena, childSeqNode(w.kind, w.slots[0..w.count]));
}

fn binDrain(cursor: *BinaryCursor.Cursor, iter: BinaryCursor.ChildIter) BinaryError!void {
    var it = iter;
    while (try it.next()) |entry| {
        try BinaryCursor.skipBody(cursor, entry.value);
    }
}

/// Read a binary leaf node as a `PatValue`, always consuming the node's
/// bytes. Returns `null` for non-leaf shapes (vector / form / date / time /
/// unit number), having skipped them. Note `form` is among them: a form in
/// `(pure …)` value position is a tree-path expression that the binary path
/// has no `*Ast.Tree` to evaluate, so it degrades to `silence` (the caller
/// treats this null exactly like any other non-leaf) — see `binDecodeForm`.
fn binLeafValue(arena: Allocator, cursor: *BinaryCursor.Cursor, view: BinaryCursor.NodeView) BinaryError!?PatValue {
    switch (view.kind) {
        .symbol => return .{ .symbol = try arena.dupe(u8, try BinaryCursor.readSymbol(cursor, view)) },
        .string => return .{ .string = try arena.dupe(u8, try BinaryCursor.readString(cursor, view)) },
        .keyword => return .{ .keyword = try arena.dupe(u8, try BinaryCursor.readKeyword(cursor, view)) },
        .number => switch (view.tag) {
            .number => return .{ .number = try BinaryCursor.readNumber(cursor, view) },
            .number_i64 => return .{ .integer_i64 = try BinaryCursor.readNumberI64(cursor, view) },
            .number_u64 => return .{ .integer_u64 = try BinaryCursor.readNumberU64(cursor, view) },
            else => {
                try BinaryCursor.skipBody(cursor, view);
                return null;
            },
        },
        .boolean => return .{ .boolean = try BinaryCursor.readBoolean(cursor, view) },
        .nil => {
            try BinaryCursor.readNil(cursor, view);
            return .nil;
        },
        else => {
            try BinaryCursor.skipBody(cursor, view);
            return null;
        },
    }
}

/// Build an `arity_mismatch` diagnostic, duping the borrowed head into the
/// result arena so the `Result` outlives the source tree. `msg` is a static
/// literal (no dupe needed).
fn arityDiag(arena: Allocator, hdr: Ast.FormHeader, msg: []const u8) Error!Ast.Diagnostic {
    const head_copy = try arena.dupe(u8, hdr.head);
    const path = try arena.dupe([]const u8, &.{head_copy});
    return .{
        .span = hdr.head_span,
        .message = msg,
        .severity = .err,
        .code = .arity_mismatch,
        .path = path,
    };
}

/// Build a `pure`-expression dry-run diagnostic (`pattern_value_eval_failed`
/// / `pattern_value_result_invalid`). Path is `[pure]` (the form head, duped
/// into the result arena); `msg` is already arena-owned or a static literal.
fn exprLeafDiag(arena: Allocator, hdr: Ast.FormHeader, code: Ast.Diagnostic.Code, msg: []const u8) Error!Ast.Diagnostic {
    const head_copy = try arena.dupe(u8, hdr.head); // "pure"
    const path = try arena.dupe([]const u8, &.{head_copy});
    return .{
        .span = hdr.head_span,
        .message = msg,
        .severity = .err,
        .code = code,
        .path = path,
    };
}

// ---------------------------------------------------------------------------
// Query — the single engine. A bounded heap frame-stack walker over `Node`,
// appending haps to one shared output list. Combinators map time on the way
// *down* (the child query span) and transform the produced haps *back up*
// (an in-place affine remap of the range they appended). No host recursion.
// ---------------------------------------------------------------------------

/// Affine tick remap `out_off + floor((t - in_off) * num / den)` with
/// `den > 0`. Monotonic increasing, so it preserves span order. Used as the
/// "map results back to world time" step of a scaling combinator.
const Affine = struct {
    in_off: Tick,
    num: i64,
    den: i64,
    out_off: Tick,

    fn apply(self: Affine, t: Tick) Pattern.Error!Tick {
        const shifted = try Pattern.checkedAdd(t, -self.in_off);
        const scaled = try Pattern.mulDiv(shifted, self.num, self.den);
        return Pattern.checkedAdd(scaled, self.out_off);
    }
    fn applySpan(self: Affine, s: Span) Pattern.Error!Span {
        return Span.init(try self.apply(s.begin), try self.apply(s.end));
    }
};

const QueryFrame = union(enum) {
    /// Query `node` over `span`, appending its haps to the shared output.
    query: struct { node: *const Node, span: Span },
    /// Remap (and optionally clip) the haps a child appended at
    /// `out[start..]`, in place. `clip != null` drops haps whose remapped
    /// part doesn't intersect it (the whole is remapped but never clipped).
    transform: struct { start: usize, map: Affine, clip: ?Span },
    /// One step of a `seq`'s per-(cycle-piece, slot) iteration. Re-pushes
    /// itself to advance, so frame depth stays O(pattern depth).
    seq_iter: SeqIter,
    /// One step of a `stack`'s per-child iteration — query the next child
    /// over the unmodified span. Re-pushes itself, like `seq_iter`, so a
    /// wide stack doesn't blow the frame stack.
    stack_iter: struct { children: []const *const Node, span: Span, index: usize },
    /// One step of a `slowcat`'s per-cycle-piece iteration — query the
    /// round-robin child for the next cycle-piece, shifted into that child's
    /// own cycle. Re-pushes itself so a wide window stays frame-bounded.
    slowcat_iter: struct { children: []const *const Node, cyc: Pattern.CycleIterator },
};

const SeqIter = struct {
    children: []const *const Node,
    cyc: Pattern.CycleIterator,
    piece: ?Span,
    slot: usize,
};

/// Per-query context for `pure_expr` leaf evaluation. Bundles what `Expr`
/// needs (the source `tree` the leaf indices point into, and the `schema` it
/// validated under — both MUST carry `core`, else `sin`/`+`/`rand01` resolve
/// to form literals and every expr silently becomes `result_invalid`), the
/// `seed` bound into the env, the fixed scratch allocator (reset before each
/// eval), and the `dropped`-hap counter. `tree` is null on the binary path
/// and the bare `query` entry — neither produces `pure_expr` — so the
/// `.pure_expr` arm unwraps it as an asserted invariant.
const QueryCtx = struct {
    tree: ?*const Ast.Tree,
    schema: Schema.Schema,
    seed: i64,
    scratch: *std.heap.FixedBufferAllocator,
    dropped: *usize,
    /// Host-provided outer env chained as the PARENT of every leaf eval's
    /// env: the pattern-locals `cycle`/`tick`/`seed` shadow it (an
    /// `Expr.Env` lookup searches own bindings before the parent), every
    /// other name falls through. Caller-owned; must outlive the query.
    outer_env: ?*const Expr.Env,
};

/// Outcome of evaluating one `pure_expr` leaf at one cycle. The two failure
/// arms are what the compile-time dry-run (cycle 0) turns into the
/// `pattern_value_eval_failed` / `pattern_value_result_invalid` diagnostics,
/// and what a later-cycle query turns into a counted drop — one shared eval
/// path (`evalLeaf`), so dry-run acceptance and per-hap semantics cannot
/// drift.
const LeafOutcome = union(enum) {
    /// Bridged successfully — a hap value.
    value: PatValue,
    /// `Expr` refused to evaluate: an unbound name, division by zero, an
    /// arity error, the step/depth/byte budget, or fixed-scratch exhaustion.
    /// Every member is deterministic in (expr, cycle, seed) — the scratch is
    /// a fixed buffer, so even `OutOfMemory` here is reproducible, not a host
    /// failure — so this drives a diagnostic (dry-run) or a clean drop.
    eval_failed: Expr.Error,
    /// Evaluated, but the result shape cannot be a hap value: a `form` (a
    /// misspelled / unresolved head yields a form literal, not an error), a
    /// vector, a date, or a time.
    result_invalid,
};

/// Query a compiled pattern over `window`, allocating the result haps in
/// `arena_inst` and appending any query-time diagnostics (e.g.
/// `pattern_tick_overflow`) to `diags` (arena-backed). Public
/// budget-defaulted form for a *pre-built* `Node` (no source tree) — used by
/// the depth test; cannot carry `pure_expr` leaves (those need a tree), so it
/// passes a null tree, an empty schema, and a throwaway drop counter.
pub fn query(
    arena_inst: *std.heap.ArenaAllocator,
    gpa: Allocator,
    node: *const Node,
    window: Span,
    seed: i64,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error![]const Hap {
    var dropped: usize = 0;
    return queryWithBudget(arena_inst, gpa, node, window, seed, diags, .{}, null, Schema.Schema.init(&.{}), null, &dropped);
}

/// Budget-parameterized query. `budget` lowers the result-arena byte cap
/// and/or the emitted-hap cap (see `Budget`); exposed so tests can drive
/// `MemoryBudgetExceeded` and `HapBudgetExceeded` without building an input
/// large enough to reach the production ceilings. `seed` is bound into the
/// env of `pure_expr` leaves (the literal-atom vocabulary remains
/// seed-independent). `tree` / `schema` back the `Expr` leaf evaluator (null
/// `tree` ⇒ the pattern provably has no `pure_expr`); `outer_env` chains
/// under every leaf's pattern-locals (see `QueryCtx.outer_env`); `dropped`
/// accumulates per-hap expr drops.
///
/// Haps accumulate in a `gpa`-backed scratch list (so growth frees as it
/// goes), bounded in count by `budget.haps`. The result arena grows mid-loop
/// when a `pure_expr` leaf yields a string / keyword value (duped in), so the
/// byte budget is polled every step, not just after the final dupe. Steps and
/// frame depth are bounded by `MAX_QUERY_STEPS` / `MAX_QUERY_FRAMES`.
pub fn queryWithBudget(
    arena_inst: *std.heap.ArenaAllocator,
    gpa: Allocator,
    node: *const Node,
    window: Span,
    seed: i64,
    diags: *std.ArrayList(Ast.Diagnostic),
    budget: Budget,
    tree: ?*const Ast.Tree,
    schema: Schema.Schema,
    outer_env: ?*const Expr.Env,
    dropped: *usize,
) Error![]const Hap {
    // The one gate every query entry funnels through, so the walk below can
    // use unchecked tick arithmetic (see `Span.checkTickBounds`). Window
    // endpoints are user input; a window near the `i64` extremes would
    // otherwise overflow inside `CycleIterator.next`.
    try window.checkTickBounds();

    const a = arena_inst.allocator();
    var out: std.ArrayList(Hap) = .empty;
    defer out.deinit(gpa);
    var stack: std.ArrayList(QueryFrame) = .empty;
    defer stack.deinit(gpa);

    // One fixed scratch buffer for every per-hap `Expr` leaf eval this call
    // (reset per eval). Allocated unconditionally — a single 256 KiB malloc,
    // freed on return — so the hot loop never touches `gpa`.
    const scratch_buf = try gpa.alloc(u8, PATTERN_EXPR_SCRATCH);
    defer gpa.free(scratch_buf);
    var fba = std.heap.FixedBufferAllocator.init(scratch_buf);
    var ctx: QueryCtx = .{ .tree = tree, .schema = schema, .seed = seed, .scratch = &fba, .dropped = dropped, .outer_env = outer_env };

    try stack.append(gpa, .{ .query = .{ .node = node, .span = window } });

    var steps: usize = 0;
    while (stack.items.len > 0) {
        steps += 1;
        if (steps > MAX_QUERY_STEPS) return error.DepthExceeded;
        if (stack.items.len > MAX_QUERY_FRAMES) return error.DepthExceeded;
        if (arena_inst.queryCapacity() > budget.bytes) return error.MemoryBudgetExceeded;

        const f = stack.pop().?;
        switch (f) {
            .query => |q| try processQuery(a, gpa, q.node, q.span, &out, &stack, diags, &ctx),
            .transform => |t| try processTransform(&out, t.start, t.map, t.clip),
            .seq_iter => |s| try processSeqIter(gpa, s, &out, &stack),
            .stack_iter => |s| try processStackIter(gpa, s.children, s.span, s.index, &stack),
            .slowcat_iter => |s| try processSlowcatIter(gpa, s.children, s.cyc, &out, &stack),
        }

        if (out.items.len > budget.haps) return error.HapBudgetExceeded;
    }

    const slice = try a.dupe(Hap, out.items);
    if (arena_inst.queryCapacity() > budget.bytes) return error.MemoryBudgetExceeded;
    return slice;
}

fn processQuery(
    a: Allocator,
    gpa: Allocator,
    node: *const Node,
    span: Span,
    out: *std.ArrayList(Hap),
    stack: *std.ArrayList(QueryFrame),
    diags: *std.ArrayList(Ast.Diagnostic),
    ctx: *const QueryCtx,
) Error!void {
    switch (node.*) {
        .silence => {},
        .pure => |v| {
            var it = span.cycles();
            while (it.next()) |piece| {
                const whole_begin = Pattern.cycleStart(piece.begin);
                const whole_end = try Pattern.checkedAdd(whole_begin, PPC);
                const whole = Span.init(whole_begin, whole_end);
                const part = whole.intersection(piece) orelse continue;
                try out.append(gpa, .{ .timing = .{ .whole = whole, .part = part }, .value = v });
            }
        },
        .pure_expr => |expr_idx| {
            // One hap per cycle, but the value is `Expr`-evaluated per cycle
            // with `cycle`/`tick`/`seed` bound at the cycle onset. A later-
            // cycle eval error or uncoercible result is a domain hole: drop
            // the hap and bump the counter, leaving output a clean (haps …).
            const tree = ctx.tree orelse unreachable; // tree-path only — binary never emits pure_expr
            var it = span.cycles();
            while (it.next()) |piece| {
                const whole_begin = Pattern.cycleStart(piece.begin);
                const whole_end = try Pattern.checkedAdd(whole_begin, PPC);
                const whole = Span.init(whole_begin, whole_end);
                const part = whole.intersection(piece) orelse continue;
                switch (try evalLeaf(a, ctx, tree, expr_idx, whole_begin)) {
                    .value => |v| try out.append(gpa, .{ .timing = .{ .whole = whole, .part = part }, .value = v }),
                    .eval_failed, .result_invalid => ctx.dropped.* += 1,
                }
            }
        },
        .seq => |children| {
            std.debug.assert(children.len > 0);
            try stack.append(gpa, .{ .seq_iter = .{
                .children = children,
                .cyc = span.cycles(),
                .piece = null,
                .slot = 0,
            } });
        },
        .stack => |children| {
            std.debug.assert(children.len > 0);
            try stack.append(gpa, .{ .stack_iter = .{ .children = children, .span = span, .index = 0 } });
        },
        .slowcat => |children| {
            std.debug.assert(children.len > 0);
            try stack.append(gpa, .{ .slowcat_iter = .{ .children = children, .cyc = span.cycles() } });
        },
        .scale => |sc| {
            // Child plays num/den× as fast: query it over the window scaled
            // by num/den, then map its haps back by den/num. A `fast` factor
            // can expand the window past the 2^53 tick ceiling — when the
            // forward map overflows, localize it to a collected
            // `pattern_tick_overflow` at this combinator and contribute no
            // haps (collection over abort) rather than aborting the query.
            const lo = Pattern.mulDiv(span.begin, sc.num, sc.den) catch |err| switch (err) {
                error.TickOverflow => return emitTickOverflow(a, diags, sc),
            };
            const hi = Pattern.mulDiv(span.end, sc.num, sc.den) catch |err| switch (err) {
                error.TickOverflow => return emitTickOverflow(a, diags, sc),
            };
            const back: Affine = .{ .in_off = 0, .num = sc.den, .den = sc.num, .out_off = 0 };
            try stack.append(gpa, .{ .transform = .{ .start = out.items.len, .map = back, .clip = null } });
            try stack.append(gpa, .{ .query = .{ .node = sc.child, .span = Span.init(lo, hi) } });
        },
    }
}

/// Evaluate a `pure_expr` leaf for the cycle whose onset tick is
/// `cycle_tick`. Binds the time env (`cycle` = f64 `cycle_tick/PPC`, `tick` =
/// i64 `cycle_tick`, `seed` = i64 from the query ABI) — chained over
/// `ctx.outer_env` when a host provided one, which those three names shadow —
/// and runs `Expr` against the fixed scratch (reset first), then bridges the
/// result into a `PatValue` duped into `a` (the query *result* arena). This
/// is the single eval path shared by the per-hap query (later cycles) and the
/// compile-time dry-run (cycle 0), so what the dry-run accepts is exactly
/// what queries evaluate.
///
/// `runtime = null` — core only; a `:impl "wasm:…"` plugin func is out of
/// scope for a pattern leaf and would surface as `eval_failed`. Only
/// `OutOfMemory` from the result-arena dupe escapes (a genuine host failure);
/// every `Expr` outcome is captured in the returned `LeafOutcome`.
fn evalLeaf(
    a: Allocator,
    ctx: *const QueryCtx,
    tree: *const Ast.Tree,
    expr_idx: Ast.NodeIndex,
    cycle_tick: Tick,
) Error!LeafOutcome {
    const cycle_f: f64 = @as(f64, @floatFromInt(cycle_tick)) / @as(f64, @floatFromInt(PPC));
    const bindings = [_]Expr.Env.Binding{
        .{ .name = "cycle", .value = .{ .number = cycle_f } },
        .{ .name = "tick", .value = .{ .integer_i64 = cycle_tick } },
        .{ .name = "seed", .value = .{ .integer_i64 = ctx.seed } },
    };
    const env: Expr.Env = .{ .parent = ctx.outer_env, .bindings = &bindings };

    ctx.scratch.reset();
    var result = Expr.evalWithRuntimeBudget(ctx.scratch.allocator(), tree, expr_idx, &env, ctx.schema, null, .{ .bytes = PATTERN_EXPR_BYTES }) catch |err| {
        return .{ .eval_failed = err };
    };
    defer result.deinit();
    const pv = (try fromExprValue(a, result.value)) orelse return .result_invalid;
    return .{ .value = pv };
}

/// Compile-time dry-run of a `pure`-form expression leaf at cycle 0 / seed 0.
/// Static validity is seed-independent, so cycle 0 catches the whole
/// document-defect class (unbound names, always-failing ops, non-coercible
/// shapes). Reuses `evalLeaf` — the *same* path queries run — so dry-run
/// acceptance and per-hap semantics cannot drift. Allocates a transient
/// scratch buffer from `gpa` (compile-time, once per expression leaf, freed
/// before return); the throwaway drop counter is discarded.
fn dryRunLeaf(
    arena: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    expr_idx: Ast.NodeIndex,
    schema: Schema.Schema,
    outer_env: ?*const Expr.Env,
) Error!LeafOutcome {
    const scratch_buf = try gpa.alloc(u8, PATTERN_EXPR_SCRATCH);
    defer gpa.free(scratch_buf);
    var fba = std.heap.FixedBufferAllocator.init(scratch_buf);
    var dropped: usize = 0;
    const ctx: QueryCtx = .{ .tree = tree, .schema = schema, .seed = 0, .scratch = &fba, .dropped = &dropped, .outer_env = outer_env };
    return evalLeaf(arena, &ctx, tree, expr_idx, 0);
}

/// Append a `pattern_tick_overflow` diagnostic for an overflowing `scale`
/// node. Path is the single offending combinator head (`fast` derived from
/// `num > den`, else `slow`); both are static literals (no dupe). The node
/// then contributes no haps.
fn emitTickOverflow(a: Allocator, diags: *std.ArrayList(Ast.Diagnostic), sc: Scale) Error!void {
    const head: []const u8 = if (sc.num > sc.den) "fast" else "slow";
    try diags.append(a, .{
        .span = sc.span,
        .message = "pattern time scaling overflowed the 2^53 tick ceiling",
        .severity = .err,
        .code = .pattern_tick_overflow,
        .path = try a.dupe([]const u8, &.{head}),
    });
}

/// Query one stack child over the unmodified span, then re-push to advance.
/// Children concatenate in order (each fully completes before the next).
fn processStackIter(
    gpa: Allocator,
    children: []const *const Node,
    span: Span,
    index: usize,
    stack: *std.ArrayList(QueryFrame),
) Error!void {
    if (index >= children.len) return;
    // Continuation first, child query second, so the child runs (and fully
    // appends) before the next sibling.
    try stack.append(gpa, .{ .stack_iter = .{ .children = children, .span = span, .index = index + 1 } });
    try stack.append(gpa, .{ .query = .{ .node = children[index], .span = span } });
}

/// Query one cycle-piece of a `slowcat`: child `c mod N` plays its own cycle
/// `floor(c/N)` during global cycle `c`. Shift the piece back into the
/// child's cycle, query, then translate the haps forward by the same delta.
/// `@mod` / `@divFloor` give the JS-`Math.floor` / positive-modulo semantics
/// on negative cycles. Re-pushes to advance to the next piece.
fn processSlowcatIter(
    gpa: Allocator,
    children: []const *const Node,
    cyc: Pattern.CycleIterator,
    out: *std.ArrayList(Hap),
    stack: *std.ArrayList(QueryFrame),
) Error!void {
    var it = cyc;
    const piece = it.next() orelse return;
    // Schedule the next piece first; it processes after this piece's child
    // query + transform complete.
    try stack.append(gpa, .{ .slowcat_iter = .{ .children = children, .cyc = it } });

    const n: i64 = @intCast(children.len);
    const c = Pattern.cycleOf(piece.begin);
    const i: usize = @intCast(@mod(c, n));
    const local_cycle = @divFloor(c, n);
    // delta = (c - local_cycle) * PPC — the global↔child-cycle time shift.
    const delta = try Pattern.checkedMul(c - local_cycle, PPC);
    const child_span = Span.init(
        try Pattern.checkedAdd(piece.begin, -delta),
        try Pattern.checkedAdd(piece.end, -delta),
    );
    const back: Affine = .{ .in_off = 0, .num = 1, .den = 1, .out_off = delta };

    try stack.append(gpa, .{ .transform = .{ .start = out.items.len, .map = back, .clip = null } });
    try stack.append(gpa, .{ .query = .{ .node = children[i], .span = child_span } });
}

fn processSeqIter(
    gpa: Allocator,
    state: SeqIter,
    out: *std.ArrayList(Hap),
    stack: *std.ArrayList(QueryFrame),
) Error!void {
    var st = state;
    if (st.piece == null) {
        st.piece = st.cyc.next();
        st.slot = 0;
        if (st.piece == null) return; // every cycle-piece processed
    }
    const piece = st.piece.?;
    const n: usize = st.children.len;
    if (st.slot >= n) {
        st.piece = null; // advance to the next cycle-piece
        try stack.append(gpa, .{ .seq_iter = st });
        return;
    }

    const i = st.slot;
    const n_i64: i64 = @intCast(n);
    const slot_width = @divFloor(PPC, n_i64);
    const cstart = Pattern.cycleStart(piece.begin);
    const slot_begin = try Pattern.checkedAdd(cstart, @as(i64, @intCast(i)) * slot_width);
    // Last slot absorbs the remainder so slots tile the cycle with no gap.
    const slot_end = if (i == n - 1) try Pattern.checkedAdd(cstart, PPC) else slot_begin + slot_width;
    const slot_span = Span.init(slot_begin, slot_end);

    // Advance to the next slot and schedule the continuation first, so it
    // resumes after this slot's child query + transform complete.
    st.slot = i + 1;
    try stack.append(gpa, .{ .seq_iter = st });

    const overlap = piece.intersection(slot_span) orelse return;

    // Forward map (world → child-local): the child plays its own cycle `c`
    // compressed ×N into the slot. local = cstart + (world - slot_begin) * N.
    const inner = Span.init(
        try Pattern.checkedAdd(cstart, try Pattern.checkedMul(overlap.begin - slot_begin, n_i64)),
        try Pattern.checkedAdd(cstart, try Pattern.checkedMul(overlap.end - slot_begin, n_i64)),
    );
    // Back map (child-local → world): world = slot_begin + (local - cstart)/N.
    const back: Affine = .{ .in_off = cstart, .num = 1, .den = n_i64, .out_off = slot_begin };

    try stack.append(gpa, .{ .transform = .{ .start = out.items.len, .map = back, .clip = slot_span } });
    try stack.append(gpa, .{ .query = .{ .node = st.children[i], .span = inner } });
}

fn processTransform(
    out: *std.ArrayList(Hap),
    start: usize,
    map: Affine,
    clip: ?Span,
) Error!void {
    var write = start;
    var read = start;
    while (read < out.items.len) : (read += 1) {
        const h = out.items[read];
        const mapped_part = try map.applySpan(h.timing.part);
        const new_part = if (clip) |c| (mapped_part.intersection(c) orelse continue) else mapped_part;
        const new_whole: ?Span = if (h.timing.whole) |w| try map.applySpan(w) else null;
        out.items[write] = .{ .timing = .{ .whole = new_whole, .part = new_part }, .value = h.value };
        write += 1;
    }
    out.shrinkRetainingCapacity(write);
}

// ---------------------------------------------------------------------------
// Public entry points — compile + query in one call. Used by the conformance
// harness and (later) the wasm text exports.
// ---------------------------------------------------------------------------

/// Compile the pattern at `root` and query it over `window`. Owns the
/// returned `Result`'s arena. Budget-defaulted.
pub fn queryTree(
    gpa: Allocator,
    tree: *const Ast.Tree,
    root: Ast.NodeIndex,
    schema: Schema.Schema,
    window: Span,
    seed: i64,
) Error!Result {
    return queryTreeFull(gpa, tree, root, schema, window, seed, .{}, null);
}

/// `queryTree` with a host-provided outer `Expr.Env` — the driver-integration
/// entry. `outer_env` (caller-owned, must outlive the call) is chained as the
/// PARENT env of every `(pure <form>)` leaf, in the compile-time dry-run and
/// the per-hap eval alike, so a host can bind its own names (a transport
/// clock, control values) for leaf expressions to read. The pattern-locals
/// `cycle` / `tick` / `seed` SHADOW same-named outer bindings — inside a hap
/// the pattern's time is authoritative — and a null env is exactly
/// `queryTree`. Budget-defaulted.
pub fn queryTreeWithEnv(
    gpa: Allocator,
    tree: *const Ast.Tree,
    root: Ast.NodeIndex,
    schema: Schema.Schema,
    window: Span,
    seed: i64,
    outer_env: ?*const Expr.Env,
) Error!Result {
    return queryTreeFull(gpa, tree, root, schema, window, seed, .{}, outer_env);
}

/// Budget-parameterized `queryTree`.
pub fn queryTreeWithBudget(
    gpa: Allocator,
    tree: *const Ast.Tree,
    root: Ast.NodeIndex,
    schema: Schema.Schema,
    window: Span,
    seed: i64,
    budget: Budget,
) Error!Result {
    return queryTreeFull(gpa, tree, root, schema, window, seed, budget, null);
}

/// The one compile-and-query body every `queryTree*` entry forwards to.
fn queryTreeFull(
    gpa: Allocator,
    tree: *const Ast.Tree,
    root: Ast.NodeIndex,
    schema: Schema.Schema,
    window: Span,
    seed: i64,
    budget: Budget,
    outer_env: ?*const Expr.Env,
) Error!Result {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_inst.deinit();
    const a = arena_inst.allocator();

    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    const node = try compileTree(a, gpa, tree, root, schema, outer_env, &diags);
    if (arena_inst.queryCapacity() > budget.bytes) return error.MemoryBudgetExceeded;
    var dropped: usize = 0;
    const haps = try queryWithBudget(&arena_inst, gpa, node, window, seed, &diags, budget, tree, schema, outer_env, &dropped);

    return .{
        .arena = arena_inst,
        .haps = haps,
        .diagnostics = try diags.toOwnedSlice(a),
        .dropped = dropped,
    };
}

/// Binary-IR analogue of `queryTree`: decode `bytes` via `BinaryCursor` and
/// query the resulting pattern. Owns the returned `Result`'s arena.
pub fn queryBinary(
    gpa: Allocator,
    bytes: []const u8,
    schema: Schema.Schema,
    window: Span,
    seed: i64,
) BinaryError!Result {
    return queryBinaryWithBudget(gpa, bytes, schema, window, seed, .{});
}

/// Budget-parameterized `queryBinary`.
pub fn queryBinaryWithBudget(
    gpa: Allocator,
    bytes: []const u8,
    schema: Schema.Schema,
    window: Span,
    seed: i64,
    budget: Budget,
) BinaryError!Result {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_inst.deinit();
    const a = arena_inst.allocator();

    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    const node = try compileBinary(a, gpa, bytes, schema, &diags);
    if (arena_inst.queryCapacity() > budget.bytes) return error.MemoryBudgetExceeded;
    // The binary path has no `*Ast.Tree`, so it never produces `pure_expr`
    // (an expr leaf degrades to silence in `compileBinary`); `tree = null`
    // and `dropped` stays 0.
    var dropped: usize = 0;
    const haps = try queryWithBudget(&arena_inst, gpa, node, window, seed, &diags, budget, null, schema, null, &dropped);

    return .{
        .arena = arena_inst,
        .haps = haps,
        .diagnostics = try diags.toOwnedSlice(a),
        .dropped = dropped,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build → serialize → parse → reconstruct → compare. The local Parser
/// import is test-only, so it does not enter this module's wasm closure.
fn roundTrip(gpa: Allocator, haps: []const Hap) !void {
    const Parser = @import("Parser.zig");

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const text = try serializeHaps(arena, haps);

    // Parse the serialized text back into a tree.
    const src = try arena.dupeZ(u8, text);
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);

    const got = try reconstructHaps(arena, &tree, tree.root[0]);
    try testing.expectEqual(haps.len, got.len);
    for (haps, got) |want, have| {
        try testing.expect(want.eql(have));
    }
}

test "round-trip: discrete event, whole == part (omitted)" {
    const haps = [_]Hap{
        .{ .timing = .{ .whole = Span.init(0, Pattern.PPC), .part = Span.init(0, Pattern.PPC) }, .value = .{ .symbol = "bd" } },
    };
    try roundTrip(testing.allocator, &haps);
    // The omission convention actually omits `:whole` here.
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const text = try serializeHaps(arena_inst.allocator(), &haps);
    try testing.expect(std.mem.indexOf(u8, text, ":whole") == null);
}

test "round-trip: clipped fragment, whole != part (emitted)" {
    const haps = [_]Hap{
        .{ .timing = .{ .whole = Span.init(-5, Pattern.PPC), .part = Span.init(0, Pattern.PPC) }, .value = .{ .symbol = "sn" } },
    };
    try roundTrip(testing.allocator, &haps);
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const text = try serializeHaps(arena_inst.allocator(), &haps);
    try testing.expect(std.mem.indexOf(u8, text, ":whole [-5 ") != null);
}

test "round-trip: continuous sample, whole == null" {
    const haps = [_]Hap{
        .{ .timing = .{ .whole = null, .part = Span.init(42, 42) }, .value = .{ .number = 0.5 } },
    };
    try roundTrip(testing.allocator, &haps);
}

test "round-trip: every value variant" {
    const haps = [_]Hap{
        .{ .timing = .{ .whole = Span.init(0, 10), .part = Span.init(0, 10) }, .value = .{ .symbol = "kick" } },
        .{ .timing = .{ .whole = Span.init(10, 20), .part = Span.init(10, 20) }, .value = .{ .string = "a \"quoted\"\n line" } },
        .{ .timing = .{ .whole = Span.init(20, 30), .part = Span.init(20, 30) }, .value = .{ .keyword = "loop" } },
        .{ .timing = .{ .whole = Span.init(30, 40), .part = Span.init(30, 40) }, .value = .{ .number = 1.5 } },
        .{ .timing = .{ .whole = Span.init(40, 50), .part = Span.init(40, 50) }, .value = .{ .number = 2.0 } },
        .{ .timing = .{ .whole = Span.init(50, 60), .part = Span.init(50, 60) }, .value = .{ .integer_i64 = -7 } },
        .{ .timing = .{ .whole = Span.init(60, 70), .part = Span.init(60, 70) }, .value = .{ .integer_u64 = 18446744073709551615 } },
        .{ .timing = .{ .whole = Span.init(70, 80), .part = Span.init(70, 80) }, .value = .{ .boolean = true } },
        .{ .timing = .{ .whole = Span.init(80, 90), .part = Span.init(80, 90) }, .value = .{ .boolean = false } },
        .{ .timing = .{ .whole = Span.init(90, 100), .part = Span.init(90, 100) }, .value = .nil },
    };
    try roundTrip(testing.allocator, &haps);
}

test "round-trip: empty hap list" {
    const haps = [_]Hap{};
    try roundTrip(testing.allocator, &haps);
}

test "reconstruct rejects malformed shapes" {
    const Parser = @import("Parser.zig");
    const bad = [_][:0]const u8{
        "(nothaps)", // wrong head
        "(haps bd)", // child not a (hap …) form
        "(haps (hap :part [0] bd))", // span not a pair
        "(haps (hap :whole nil bd))", // missing :part
        "(haps (hap :part [0 10]))", // missing positional value
        "(haps (hap :part [0 10] :bogus 1 bd))", // unknown kvpair key
        "(haps (hap :part [10 0] bd))", // reversed span
        "(haps (hap :part [0 10] bd sn))", // two positional values
    };
    for (bad) |src| {
        var tree = try Parser.parse(testing.allocator, src);
        defer tree.deinit();
        var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        try testing.expectError(error.MalformedHapForm, reconstructHaps(arena_inst.allocator(), &tree, tree.root[0]));
    }
}

// -- Engine (compile + query) ----------------------------------------------

fn patternSchema() Schema.Schema {
    const core_plugin = @import("plugins/core.zig").plugin;
    const pattern_plugin = @import("plugins/pattern.zig").plugin;
    return Schema.Schema.init(&.{ core_plugin, pattern_plugin });
}

/// Parse `src`, compile + query over `window`, return the owned Result.
fn querySource(gpa: Allocator, src: [:0]const u8, window: Span) !Result {
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    return queryTree(gpa, &tree, tree.root[0], patternSchema(), window, 0);
}

fn expectHaps(result: Result, expected: []const Hap) !void {
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try testing.expectEqual(expected.len, result.haps.len);
    for (expected, result.haps) |want, have| {
        if (!want.eql(have)) {
            std.debug.print("hap mismatch:\n want part=[{d} {d}] whole={?}\n have part=[{d} {d}] whole={?}\n", .{
                want.timing.part.begin, want.timing.part.end, want.timing.whole,
                have.timing.part.begin, have.timing.part.end, have.timing.whole,
            });
            return error.HapMismatch;
        }
    }
}

fn sym(s: []const u8) PatValue {
    return .{ .symbol = s };
}

test "query: bare symbol is pure, one hap per cycle" {
    var r = try querySource(testing.allocator, "bd", Span.init(0, PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = sym("bd") },
    });
}

test "query: (pure v) equals bare v" {
    var r = try querySource(testing.allocator, "(pure bd)", Span.init(0, PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = sym("bd") },
    });
}

test "query: pure repeats every cycle across a multi-cycle window" {
    var r = try querySource(testing.allocator, "bd", Span.init(0, 2 * PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(PPC, 2 * PPC), .part = Span.init(PPC, 2 * PPC) }, .value = sym("bd") },
    });
}

test "query: silence form yields nothing" {
    var r = try querySource(testing.allocator, "(silence)", Span.init(0, 3 * PPC));
    defer r.deinit();
    try expectHaps(r, &.{});
}

test "query: [bd sn] tiles a cycle into two equal slots" {
    const half = @divExact(PPC, 2);
    var r = try querySource(testing.allocator, "[bd sn]", Span.init(0, PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, half), .part = Span.init(0, half) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(half, PPC), .part = Span.init(half, PPC) }, .value = sym("sn") },
    });
}

test "query: nested [[bd sn] hh] subdivides the first half again" {
    const half = @divExact(PPC, 2);
    const quarter = @divExact(PPC, 4);
    var r = try querySource(testing.allocator, "[[bd sn] hh]", Span.init(0, PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, quarter), .part = Span.init(0, quarter) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(quarter, half), .part = Span.init(quarter, half) }, .value = sym("sn") },
        .{ .timing = .{ .whole = Span.init(half, PPC), .part = Span.init(half, PPC) }, .value = sym("hh") },
    });
}

test "query: empty vector compiles to silence" {
    var r = try querySource(testing.allocator, "[]", Span.init(0, PPC));
    defer r.deinit();
    try expectHaps(r, &.{});
}

test "query: negative window spans cycle -1 and 0" {
    const half = @divExact(PPC, 2);
    var r = try querySource(testing.allocator, "bd", Span.init(-half, half));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(-PPC, 0), .part = Span.init(-half, 0) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, half) }, .value = sym("bd") },
    });
}

test "query: zero-width window samples the discrete hap at an interior point" {
    const t = @divExact(PPC, 3);
    var r = try querySource(testing.allocator, "bd", Span.init(t, t));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(t, t) }, .value = sym("bd") },
    });
}

test "query: [bd sn] queried over the second half only yields sn" {
    const half = @divExact(PPC, 2);
    var r = try querySource(testing.allocator, "[bd sn]", Span.init(half, PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(half, PPC), .part = Span.init(half, PPC) }, .value = sym("sn") },
    });
}

test "compile: (pure) with wrong arity emits arity_mismatch and falls to silence" {
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(testing.allocator, "(pure bd sn)");
    defer tree.deinit();
    var r = try queryTree(testing.allocator, &tree, tree.root[0], patternSchema(), Span.init(0, PPC), 0);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.arity_mismatch, r.diagnostics[0].code);
    try testing.expectEqual(@as(usize, 0), r.haps.len);
}

test "query: determinism — same pattern + window twice is identical" {
    var r1 = try querySource(testing.allocator, "[bd [sn hh]]", Span.init(0, 2 * PPC));
    defer r1.deinit();
    var r2 = try querySource(testing.allocator, "[bd [sn hh]]", Span.init(0, 2 * PPC));
    defer r2.deinit();
    try testing.expectEqual(r1.haps.len, r2.haps.len);
    for (r1.haps, r2.haps) |a, b| try testing.expect(a.eql(b));
}

test "query: literal patterns are seed-independent — distinct seeds give byte-identical haps" {
    // `seed` is now consumed — but ONLY by `pure_expr` leaves, where it binds
    // the `seed` env name (`(pure (rand01 seed cycle))`). The literal-atom /
    // combinator vocabulary stays seed-independent: a pattern with no
    // expression leaf must produce byte-identical haps under any seed. Lock
    // that here with an expr-free pattern, so a future seed-sensitive
    // *combinator* (degradeBy/RNG) trips this and forces a deliberate update
    // rather than silently acquiring meaning. (Seed-*sensitive* expr leaves
    // are locked separately, below.)
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(testing.allocator, "(stack (fast 2 [bd sn]) (cat hh oh sd))");
    defer tree.deinit();

    const window = Span.init(-PPC, 3 * PPC); // negative + multi-cycle, exercises the cat shift
    var r0 = try queryTree(testing.allocator, &tree, tree.root[0], patternSchema(), window, 0);
    defer r0.deinit();
    var r1 = try queryTree(testing.allocator, &tree, tree.root[0], patternSchema(), window, 0x7FFF_FFFF_FFFF_FFFF);
    defer r1.deinit();

    try testing.expectEqual(@as(usize, 0), r0.diagnostics.len);
    try testing.expect(r0.haps.len > 0); // non-trivial: not vacuously equal
    try testing.expectEqual(r0.haps.len, r1.haps.len);
    for (r0.haps, r1.haps) |a, b| try testing.expect(a.eql(b));
}

test "query: budget trip — tiny byte cap yields MemoryBudgetExceeded" {
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(testing.allocator, "[bd sn hh]");
    defer tree.deinit();
    try testing.expectError(
        error.MemoryBudgetExceeded,
        queryTreeWithBudget(testing.allocator, &tree, tree.root[0], patternSchema(), Span.init(0, PPC), 0, .{ .bytes = 1 }),
    );
}

test "query: budget trip — tiny hap cap yields HapBudgetExceeded" {
    // The count amplifier the cap exists for: `(fast N …)` is one node and a
    // handful of steps, but emits N haps per cycle per leaf. With the
    // production `MAX_HAPS` this needs an input nobody would write; with the
    // seam it is four haps against a cap of three.
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(testing.allocator, "(fast 4 bd)");
    defer tree.deinit();

    try testing.expectError(
        error.HapBudgetExceeded,
        queryTreeWithBudget(testing.allocator, &tree, tree.root[0], patternSchema(), Span.init(0, PPC), 0, .{ .haps = 3 }),
    );

    // …and the same pattern under the same window is clean when the cap
    // admits it, so the trip is the budget and not the pattern.
    var ok = try queryTreeWithBudget(testing.allocator, &tree, tree.root[0], patternSchema(), Span.init(0, PPC), 0, .{ .haps = 4 });
    defer ok.deinit();
    try testing.expectEqual(@as(usize, 4), ok.haps.len);
}

test "query: budget trip — the binary front-end honors the same hap cap" {
    // `queryBinary` reaches `queryWithBudget` down its own path (no tree, no
    // expr leaves). The dual-path discipline: a ceiling proven on one entry
    // says nothing about the other.
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    var tree = try Parser.parse(testing.allocator, "(fast 4 bd)");
    defer tree.deinit();
    var bytes = try Binary.toBinary(testing.allocator, tree, .{});
    defer bytes.deinit();

    try testing.expectError(
        error.HapBudgetExceeded,
        queryBinaryWithBudget(testing.allocator, bytes.data, patternSchema(), Span.init(0, PPC), 0, .{ .haps = 3 }),
    );

    var ok = try queryBinaryWithBudget(testing.allocator, bytes.data, patternSchema(), Span.init(0, PPC), 0, .{ .haps = 4 });
    defer ok.deinit();
    try testing.expectEqual(@as(usize, 4), ok.haps.len);
}

test "resultToText: haps when clean, diagnostics when any collected" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    // Clean result → (haps …).
    const clean: Result = .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .haps = &.{.{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = sym("bd") }},
        .diagnostics = &.{},
    };
    const haps_text = try resultToText(a, clean);
    try testing.expectEqualStrings("(haps (hap :part [0 720720] bd))", haps_text);

    // Any diagnostic → (diagnostics …) (haps suppressed).
    const path = [_][]const u8{"fast"};
    const diag: Ast.Diagnostic = .{ .span = .{ .start = 0, .end = 0 }, .message = "x", .code = .pattern_tick_overflow, .path = &path };
    const dirty: Result = .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .haps = &.{},
        .diagnostics = &.{diag},
    };
    const diag_text = try resultToText(a, dirty);
    try testing.expectEqualStrings("(diagnostics (diagnostic :code pattern_tick_overflow :path [fast]))", diag_text);
}

// -- fast / slow / stack ---------------------------------------------------

test "query: (fast 2 bd) plays twice per cycle" {
    const half = @divExact(PPC, 2);
    var r = try querySource(testing.allocator, "(fast 2 bd)", Span.init(0, PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, half), .part = Span.init(0, half) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(half, PPC), .part = Span.init(half, PPC) }, .value = sym("bd") },
    });
}

test "query: (fast 2 [bd sn]) is bd sn bd sn" {
    const q = @divExact(PPC, 4);
    var r = try querySource(testing.allocator, "(fast 2 [bd sn])", Span.init(0, PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, q), .part = Span.init(0, q) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(q, 2 * q), .part = Span.init(q, 2 * q) }, .value = sym("sn") },
        .{ .timing = .{ .whole = Span.init(2 * q, 3 * q), .part = Span.init(2 * q, 3 * q) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(3 * q, PPC), .part = Span.init(3 * q, PPC) }, .value = sym("sn") },
    });
}

test "query: (slow 2 bd) stretches one hap over two cycles" {
    var r = try querySource(testing.allocator, "(slow 2 bd)", Span.init(0, 2 * PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, 2 * PPC), .part = Span.init(0, 2 * PPC) }, .value = sym("bd") },
    });
}

test "query: (slow 2 bd) over one cycle is the clipped first half of a 2-cycle whole" {
    var r = try querySource(testing.allocator, "(slow 2 bd)", Span.init(0, PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, 2 * PPC), .part = Span.init(0, PPC) }, .value = sym("bd") },
    });
    try testing.expect(r.haps[0].timing.hasOnset());
}

test "query: (stack bd sn) layers both children over the whole cycle" {
    var r = try querySource(testing.allocator, "(stack bd sn)", Span.init(0, PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = sym("sn") },
    });
}

test "query: fast 0 / negative / non-integer factor compile to silence" {
    inline for (.{ "(fast 0 bd)", "(fast -2 bd)", "(slow 0 bd)", "(fast 1.5 bd)" }) |src| {
        var r = try querySource(testing.allocator, src, Span.init(0, PPC));
        defer r.deinit();
        try expectHaps(r, &.{});
    }
}

test "compile: (fast) with wrong arity emits arity_mismatch" {
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(testing.allocator, "(fast 2)");
    defer tree.deinit();
    var r = try queryTree(testing.allocator, &tree, tree.root[0], patternSchema(), Span.init(0, PPC), 0);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.arity_mismatch, r.diagnostics[0].code);
}

test "query: nested fast factor overflow is a collected pattern_tick_overflow" {
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(testing.allocator, "(fast 1000000000 (fast 1000000000 bd))");
    defer tree.deinit();
    var r = try queryTree(testing.allocator, &tree, tree.root[0], patternSchema(), Span.init(0, PPC), 0);
    defer r.deinit();
    // Collection over abort: no haps, one localized diagnostic.
    try testing.expectEqual(@as(usize, 0), r.haps.len);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.pattern_tick_overflow, r.diagnostics[0].code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics[0].path.len);
    try testing.expectEqualStrings("fast", r.diagnostics[0].path[0]);
}

test "query: a sibling of an overflowing scale still produces haps" {
    // collection-over-abort: the overflowing fast contributes nothing, but
    // the stacked `bd` is unaffected.
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(testing.allocator, "(stack (fast 1000000000 (fast 1000000000 x)) bd)");
    defer tree.deinit();
    var r = try queryTree(testing.allocator, &tree, tree.root[0], patternSchema(), Span.init(0, PPC), 0);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.pattern_tick_overflow, r.diagnostics[0].code);
    try testing.expectEqual(@as(usize, 1), r.haps.len);
    try testing.expect(r.haps[0].value.eql(sym("bd")));
}

// -- slowcat / cat ---------------------------------------------------------

test "query: (cat bd sn) plays bd in cycle 0, sn in cycle 1" {
    var r = try querySource(testing.allocator, "(cat bd sn)", Span.init(0, 2 * PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(PPC, 2 * PPC), .part = Span.init(PPC, 2 * PPC) }, .value = sym("sn") },
    });
}

test "query: (cat bd sn) over cycle 0 only yields bd" {
    var r = try querySource(testing.allocator, "(cat bd sn)", Span.init(0, PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = sym("bd") },
    });
}

test "query: slowcat round-robins across four cycles" {
    var r = try querySource(testing.allocator, "(slowcat a b)", Span.init(0, 4 * PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = sym("a") },
        .{ .timing = .{ .whole = Span.init(PPC, 2 * PPC), .part = Span.init(PPC, 2 * PPC) }, .value = sym("b") },
        .{ .timing = .{ .whole = Span.init(2 * PPC, 3 * PPC), .part = Span.init(2 * PPC, 3 * PPC) }, .value = sym("a") },
        .{ .timing = .{ .whole = Span.init(3 * PPC, 4 * PPC), .part = Span.init(3 * PPC, 4 * PPC) }, .value = sym("b") },
    });
}

test "query: (cat bd sn) on negative cycle -1 yields sn (positive modulo)" {
    var r = try querySource(testing.allocator, "(cat bd sn)", Span.init(-PPC, 0));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(-PPC, 0), .part = Span.init(-PPC, 0) }, .value = sym("sn") },
    });
}

test "query: cat of seqs nests fastcat inside one cycle each" {
    const half = @divExact(PPC, 2);
    // cycle 0 plays [bd sn] (two slots); cycle 1 plays hh (whole cycle).
    var r = try querySource(testing.allocator, "(cat [bd sn] hh)", Span.init(0, 2 * PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, half), .part = Span.init(0, half) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(half, PPC), .part = Span.init(half, PPC) }, .value = sym("sn") },
        .{ .timing = .{ .whole = Span.init(PPC, 2 * PPC), .part = Span.init(PPC, 2 * PPC) }, .value = sym("hh") },
    });
}

test "query: (euclid 3 8 bd) is the tresillo x..x..x." {
    const slot = @divExact(PPC, 8);
    var r = try querySource(testing.allocator, "(euclid 3 8 bd)", Span.init(0, PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, slot), .part = Span.init(0, slot) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(3 * slot, 4 * slot), .part = Span.init(3 * slot, 4 * slot) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(6 * slot, 7 * slot), .part = Span.init(6 * slot, 7 * slot) }, .value = sym("bd") },
    });
}

test "query: (euclid 5 8 bd) is the cinquillo x.xx.xx." {
    const slot = @divExact(PPC, 8);
    var r = try querySource(testing.allocator, "(euclid 5 8 bd)", Span.init(0, PPC));
    defer r.deinit();
    var want: [5]Hap = undefined;
    for ([_]i64{ 0, 2, 3, 5, 6 }, 0..) |i, w| {
        const s = Span.init(i * slot, (i + 1) * slot);
        want[w] = .{ .timing = .{ .whole = s, .part = s }, .value = sym("bd") };
    }
    try expectHaps(r, &want);
}

test "query: (euclid 2 3 bd) repeats every cycle" {
    const slot = @divExact(PPC, 3);
    var r = try querySource(testing.allocator, "(euclid 2 3 bd)", Span.init(0, 2 * PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, slot), .part = Span.init(0, slot) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(slot, 2 * slot), .part = Span.init(slot, 2 * slot) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(PPC, PPC + slot), .part = Span.init(PPC, PPC + slot) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(PPC + slot, PPC + 2 * slot), .part = Span.init(PPC + slot, PPC + 2 * slot) }, .value = sym("bd") },
    });
}

test "query: (euclid 4 4 bd) fires every slot" {
    const slot = @divExact(PPC, 4);
    var r = try querySource(testing.allocator, "(euclid 4 4 bd)", Span.init(0, PPC));
    defer r.deinit();
    var want: [4]Hap = undefined;
    for (0..4) |i| {
        const s = Span.init(@as(i64, @intCast(i)) * slot, (@as(i64, @intCast(i)) + 1) * slot);
        want[i] = .{ .timing = .{ .whole = s, .part = s }, .value = sym("bd") };
    }
    try expectHaps(r, &want);
}

test "query: (euclid 2 4 [bd sn]) compresses the child pattern into each onset slot" {
    // Onset slots 0 and 2 (E(2,4) = x.x.); the [bd sn] fastcat plays one
    // full cycle inside each — the same child-plays-its-cycle rule as seq.
    const slot = @divExact(PPC, 4);
    const half = @divExact(slot, 2);
    var r = try querySource(testing.allocator, "(euclid 2 4 [bd sn])", Span.init(0, PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, half), .part = Span.init(0, half) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(half, slot), .part = Span.init(half, slot) }, .value = sym("sn") },
        .{ .timing = .{ .whole = Span.init(2 * slot, 2 * slot + half), .part = Span.init(2 * slot, 2 * slot + half) }, .value = sym("bd") },
        .{ .timing = .{ .whole = Span.init(2 * slot + half, 3 * slot), .part = Span.init(2 * slot + half, 3 * slot) }, .value = sym("sn") },
    });
}

test "query: euclid zero pulses / out-of-domain / non-integer args compile to silence" {
    inline for (.{
        "(euclid 0 8 bd)", // zero pulses — the empty rhythm
        "(euclid 9 8 bd)", // more pulses than steps
        "(euclid 3 0 bd)", // zero steps
        "(euclid -1 8 bd)", // negative pulses
        "(euclid 3 -8 bd)", // negative steps
        "(euclid 1.5 8 bd)", // non-integer pulses
        "(euclid 3 8.5 bd)", // non-integer steps
    }) |src| {
        var r = try querySource(testing.allocator, src, Span.init(0, PPC));
        defer r.deinit();
        try expectHaps(r, &.{});
    }
}

test "compile: (euclid) with wrong arity emits arity_mismatch" {
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(testing.allocator, "(euclid 3 8)");
    defer tree.deinit();
    var r = try queryTree(testing.allocator, &tree, tree.root[0], patternSchema(), Span.init(0, PPC), 0);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.haps.len);
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.arity_mismatch, r.diagnostics[0].code);
}

// -- pure_expr (Expr-valued leaves) ----------------------------------------

/// Like `querySource` but with an explicit seed (for `rand01` leaves).
fn querySourceSeed(gpa: Allocator, src: [:0]const u8, window: Span, seed: i64) !Result {
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    return queryTree(gpa, &tree, tree.root[0], patternSchema(), window, seed);
}

test "query: (pure (+ 1 2)) evaluates the expr leaf to a number" {
    var r = try querySource(testing.allocator, "(pure (+ 1 2))", Span.init(0, PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = .{ .number = 3.0 } },
    });
    try testing.expectEqual(@as(usize, 0), r.dropped);
}

test "query: (pure cycle) stays a literal symbol — only a FORM child is an expr" {
    // Routing rule: a bare symbol child of pure is the literal atom `cycle`,
    // identical every cycle — NOT the cycle index. Reading it as an
    // expression would silently change the meaning of every existing atom.
    var r = try querySource(testing.allocator, "(pure cycle)", Span.init(0, 2 * PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = sym("cycle") },
        .{ .timing = .{ .whole = Span.init(PPC, 2 * PPC), .part = Span.init(PPC, 2 * PPC) }, .value = sym("cycle") },
    });
}

test "query: expr leaf re-evaluates per cycle — cycle binding advances" {
    var r = try querySource(testing.allocator, "(pure (+ cycle 0))", Span.init(0, 3 * PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = .{ .number = 0.0 } },
        .{ .timing = .{ .whole = Span.init(PPC, 2 * PPC), .part = Span.init(PPC, 2 * PPC) }, .value = .{ .number = 1.0 } },
        .{ .timing = .{ .whole = Span.init(2 * PPC, 3 * PPC), .part = Span.init(2 * PPC, 3 * PPC) }, .value = .{ .number = 2.0 } },
    });
}

test "query: tick binds to the cycle onset (i64) inside an expr leaf" {
    // Over cycle 1 only: tick == PPC at the onset; `(+ tick 0)` collapses to
    // a number, so the hap value is 720720.0.
    var r = try querySource(testing.allocator, "(pure (+ tick 0))", Span.init(PPC, 2 * PPC));
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(PPC, 2 * PPC), .part = Span.init(PPC, 2 * PPC) }, .value = .{ .number = @floatFromInt(PPC) } },
    });
}

test "query: (fast 4 (pure (sin LFO))) is a pure function of cycle, not of the window" {
    // The expr value depends only on `cycle`, so the haps over [0,PPC) must
    // be byte-identical to the first four haps over [0,2·PPC) — modulation is
    // window-independent (referential transparency per cycle), and trig rides
    // through with no signal-specific code (sin64 is vendored, bit-exact).
    const src = "(fast 4 (pure (* 0.5 (+ 1 (sin (* (tau) cycle))))))";
    var small = try querySource(testing.allocator, src, Span.init(0, PPC));
    defer small.deinit();
    var big = try querySource(testing.allocator, src, Span.init(0, 2 * PPC));
    defer big.deinit();
    try testing.expectEqual(@as(usize, 4), small.haps.len);
    try testing.expectEqual(@as(usize, 8), big.haps.len);
    for (small.haps, big.haps[0..4]) |s, b| try testing.expect(s.eql(b));
    // Every value is a real number in [0,1]; non-trivially modulated.
    for (small.haps) |h| {
        try testing.expect(h.value == .number);
        try testing.expect(h.value.number >= 0.0 and h.value.number <= 1.0);
    }
}

test "query: (pure (rand01 seed cycle)) — seed-sensitive, per-cycle deterministic" {
    const src = "(pure (rand01 seed cycle))";
    const window = Span.init(0, 3 * PPC);
    var a0 = try querySourceSeed(testing.allocator, src, window, 1);
    defer a0.deinit();
    var a1 = try querySourceSeed(testing.allocator, src, window, 1);
    defer a1.deinit();
    var b = try querySourceSeed(testing.allocator, src, window, 2);
    defer b.deinit();

    try testing.expectEqual(@as(usize, 3), a0.haps.len);
    // Same seed → byte-identical haps (determinism).
    for (a0.haps, a1.haps) |x, y| try testing.expect(x.eql(y));
    // Distinct seeds → at least one differing hap (seed is load-bearing).
    var any_diff = false;
    for (a0.haps, b.haps) |x, y| {
        if (!x.eql(y)) any_diff = true;
    }
    try testing.expect(any_diff);
    // Each draw is a unit float.
    for (a0.haps) |h| {
        try testing.expect(h.value == .number);
        try testing.expect(h.value.number >= 0.0 and h.value.number < 1.0);
    }
}

test "query: a later-cycle eval failure is a counted drop, not a diagnostic" {
    // (/ 1 (- cycle 2)) is undefined at cycle 2 (division by zero) — a domain
    // hole, not a document defect. Over [0,4·PPC) the haps are at cycles
    // 0/1/3 with a hole at 2; output stays a clean (haps …); `dropped == 1`.
    var r = try querySource(testing.allocator, "(pure (/ 1 (- cycle 2)))", Span.init(0, 4 * PPC));
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len); // no diagnostic
    try testing.expectEqual(@as(usize, 1), r.dropped); // exactly the cycle-2 hole
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = .{ .number = -0.5 } },
        .{ .timing = .{ .whole = Span.init(PPC, 2 * PPC), .part = Span.init(PPC, 2 * PPC) }, .value = .{ .number = -1.0 } },
        .{ .timing = .{ .whole = Span.init(3 * PPC, 4 * PPC), .part = Span.init(3 * PPC, 4 * PPC) }, .value = .{ .number = 1.0 } },
    });
}

test "compile: (pure (bogusfn cycle)) → pattern_value_result_invalid + silence" {
    // A misspelled head evaluates to a form LITERAL (Expr form-construction),
    // not an error — caught at the cycle-0 dry-run as an uncoercible result.
    // A *static* defect becomes a diagnostic (not a counted drop): the leaf
    // degrades to silence and, because resultToText is (diagnostics …) xor
    // (haps …), the whole result is the diagnostic.
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(testing.allocator, "(pure (bogusfn cycle))");
    defer tree.deinit();
    var r = try queryTree(testing.allocator, &tree, tree.root[0], patternSchema(), Span.init(0, 2 * PPC), 0);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.pattern_value_result_invalid, r.diagnostics[0].code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics[0].path.len);
    try testing.expectEqualStrings("pure", r.diagnostics[0].path[0]);
    try testing.expectEqual(@as(usize, 0), r.haps.len);
    try testing.expectEqual(@as(usize, 0), r.dropped); // a diagnostic, not a drop
}

test "compile: an unbound name inside a pure expr → pattern_value_eval_failed + silence" {
    // A bare symbol child is a literal atom (no eval); an unbound name INSIDE
    // an expression form fails the dry-run with UnknownBinding → eval_failed.
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(testing.allocator, "(pure (+ nope 0))");
    defer tree.deinit();
    var r = try queryTree(testing.allocator, &tree, tree.root[0], patternSchema(), Span.init(0, PPC), 0);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.pattern_value_eval_failed, r.diagnostics[0].code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics[0].path.len);
    try testing.expectEqualStrings("pure", r.diagnostics[0].path[0]);
    try testing.expectEqual(@as(usize, 0), r.haps.len);
}

// -- outer env (queryTreeWithEnv) ------------------------------------------

/// Like `querySourceSeed` but threading a host-provided outer `Expr.Env`
/// through `queryTreeWithEnv` — the driver-integration entry (a host binds
/// its transport clock / controls; pattern-locals shadow it).
fn querySourceEnv(gpa: Allocator, src: [:0]const u8, window: Span, seed: i64, outer_env: ?*const Expr.Env) !Result {
    const Parser = @import("Parser.zig");
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    return queryTreeWithEnv(gpa, &tree, tree.root[0], patternSchema(), window, seed, outer_env);
}

test "queryTreeWithEnv: outer bindings reach (pure …) leaves — dry-run and eval" {
    // `beat` exists only in the outer env: without it this document is a
    // static defect (pinned by the null-env test below), so a clean result
    // proves the env reaches BOTH the compile-time leaf dry-run and the
    // per-hap eval.
    const bindings = [_]Expr.Env.Binding{
        .{ .name = "beat", .value = .{ .number = 3.0 } },
    };
    const env: Expr.Env = .{ .bindings = &bindings };
    var r = try querySourceEnv(testing.allocator, "(pure (* beat 2))", Span.init(0, PPC), 0, &env);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
    try testing.expectEqual(@as(usize, 0), r.dropped);
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = .{ .number = 6.0 } },
    });
}

test "queryTreeWithEnv: pattern-locals shadow the outer cycle/tick/seed" {
    // The outer env binds all three pattern-local names to decoys; leaves
    // must still see the pattern's own cycle-onset bindings (`Expr.Env`
    // lookup searches own bindings before the parent). Queried over cycle 1
    // with seed 7 so every true value differs from its decoy.
    const bindings = [_]Expr.Env.Binding{
        .{ .name = "cycle", .value = .{ .number = 99.0 } },
        .{ .name = "tick", .value = .{ .integer_i64 = -5 } },
        .{ .name = "seed", .value = .{ .integer_i64 = 1000 } },
    };
    const env: Expr.Env = .{ .bindings = &bindings };
    const third = @divExact(PPC, 3);
    var r = try querySourceEnv(
        testing.allocator,
        "[(pure (+ cycle 0)) (pure (+ tick 0)) (pure (+ seed 0))]",
        Span.init(PPC, 2 * PPC),
        7,
        &env,
    );
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
    try testing.expectEqual(@as(usize, 0), r.dropped);
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(PPC, PPC + third), .part = Span.init(PPC, PPC + third) }, .value = .{ .number = 1.0 } },
        .{ .timing = .{ .whole = Span.init(PPC + third, PPC + 2 * third), .part = Span.init(PPC + third, PPC + 2 * third) }, .value = .{ .number = @floatFromInt(PPC) } },
        .{ .timing = .{ .whole = Span.init(PPC + 2 * third, 2 * PPC), .part = Span.init(PPC + 2 * third, 2 * PPC) }, .value = .{ .number = 7.0 } },
    });
}

test "queryTreeWithEnv: a null env is exactly queryTree — outer names stay unbound" {
    // The env is additive: with none, `(pure (* beat 2))` stays the static
    // defect it always was (UnknownBinding at the dry-run → diagnostic, the
    // leaf degrades to silence).
    var r = try querySourceEnv(testing.allocator, "(pure (* beat 2))", Span.init(0, PPC), 0, null);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.pattern_value_eval_failed, r.diagnostics[0].code);
    try testing.expectEqual(@as(usize, 0), r.haps.len);
}

// -- tree ≡ binary property ------------------------------------------------

/// Parse `src`, query via the tree path and via the binary path
/// (toBinary → queryBinary), and assert identical haps + identical
/// `(code, path)` diagnostics. The proof that both decoders produce the
/// same `Node`.
fn expectTreeEqBinary(gpa: Allocator, src: [:0]const u8, window: Span) !void {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");

    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    var tr = try queryTree(gpa, &tree, tree.root[0], patternSchema(), window, 0);
    defer tr.deinit();

    var bytes = try Binary.toBinary(gpa, tree, .{});
    defer bytes.deinit();
    var br = try queryBinary(gpa, bytes.data, patternSchema(), window, 0);
    defer br.deinit();

    try testing.expectEqual(tr.haps.len, br.haps.len);
    for (tr.haps, br.haps, 0..) |ta, ba, i| {
        if (!ta.eql(ba)) {
            std.debug.print("tree≡binary hap {d} mismatch for `{s}`\n", .{ i, src });
            return error.TreeBinaryHapMismatch;
        }
    }
    try testing.expectEqual(tr.diagnostics.len, br.diagnostics.len);
    for (tr.diagnostics, br.diagnostics) |ta, ba| {
        try testing.expectEqual(ta.code, ba.code);
        try testing.expectEqual(ta.path.len, ba.path.len);
        for (ta.path, ba.path) |pa, pb| try testing.expectEqualStrings(pa, pb);
    }
}

test "tree ≡ binary: vector patterns under the full (comment) preset" {
    // Wire v5 gives every vector a trailing-comment count under `.full`.
    // PatternQuery's binVecWalk drives its VectorIter to null, so the
    // terminal next() drains that count for free — lock it here (a future
    // early-stop rewrite would desync and trip this).
    const gpa = testing.allocator;
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const window = Span.init(0, 4 * PPC);

    inline for (.{ "[bd sn]", "[bd [sn hh] cp]", "(fast 2 [bd sn])" }) |src| {
        var tree = try Parser.parse(gpa, src);
        defer tree.deinit();
        var tr = try queryTree(gpa, &tree, tree.root[0], patternSchema(), window, 0);
        defer tr.deinit();

        var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.full));
        defer bytes.deinit();
        var br = try queryBinary(gpa, bytes.data, patternSchema(), window, 0);
        defer br.deinit();

        try testing.expectEqual(tr.haps.len, br.haps.len);
        for (tr.haps, br.haps) |ta, ba| try testing.expect(ta.eql(ba));
    }
}

test "tree ≡ binary: every combinator shape over several windows" {
    const patterns = [_][:0]const u8{
        "bd",
        "(pure bd)",
        "(silence)",
        "[bd sn]",
        "[bd [sn hh] cp]",
        "(stack bd sn hh)",
        "(fast 2 [bd sn])",
        "(slow 3 bd)",
        "(cat bd sn hh)",
        "(slowcat [bd sn] hh)",
        "(stack (fast 2 bd) (cat sn hh))",
        "(pure 5)", // exact-integer leaf
        "(pure 1.5)", // f64 leaf
        "(euclid 3 8 bd)", // tresillo — shared child (binary) ≡ duplicated child (tree)
        "(euclid 5 8 [bd sn])", // composite child in every onset slot
        "(euclid 2 3 (fast 2 bd))", // nested combinator child
        "(euclid 0 8 bd)", // empty rhythm — silence on both paths
        "(fast 1000000000 (fast 1000000000 bd))", // overflow → diagnostic on both paths
    };
    const windows = [_]Span{
        Span.init(0, PPC),
        Span.init(0, 4 * PPC),
        Span.init(-2 * PPC, 2 * PPC),
        Span.init(@divExact(PPC, 3), 5 * PPC),
    };
    for (patterns) |src| {
        for (windows) |w| {
            try expectTreeEqBinary(testing.allocator, src, w);
        }
    }
}

test "binary path: a (pure <expr>) leaf degrades to silence (deliberate divergence)" {
    // The ONE intentional tree↔binary divergence: a form in pure-value
    // position is an Expr expression. The tree path evaluates it (1 hap); the
    // binary path has no *Ast.Tree for Expr, so it degrades to silence (0
    // haps). This is why expression patterns are excluded from the tree ≡
    // binary property test above; pin the divergence here so it stays
    // deliberate, not an accident.
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const src: [:0]const u8 = "(pure (+ 1 2))";

    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    // Tree path: the expr evaluates to 3.0 — one hap, no diagnostics.
    var tr = try queryTree(testing.allocator, &tree, tree.root[0], patternSchema(), Span.init(0, PPC), 0);
    defer tr.deinit();
    try testing.expectEqual(@as(usize, 1), tr.haps.len);
    try testing.expect(tr.haps[0].value.eql(.{ .number = 3.0 }));
    try testing.expectEqual(@as(usize, 0), tr.diagnostics.len);

    // Binary path: the form leaf is not materialized as an expr — silence.
    var bytes = try Binary.toBinary(testing.allocator, tree, .{});
    defer bytes.deinit();
    var br = try queryBinary(testing.allocator, bytes.data, patternSchema(), Span.init(0, PPC), 0);
    defer br.deinit();
    try testing.expectEqual(@as(usize, 0), br.haps.len);
    try testing.expectEqual(@as(usize, 0), br.diagnostics.len);
    try testing.expectEqual(@as(usize, 0), br.dropped);
}

test "query: windows outside the MAX_TICK ceiling return TickOverflow, not a panic" {
    // `--begin=`/`--end=` are user input, and the walk uses unchecked i64
    // arithmetic (`cycleStart(t) + PPC`). Without the entry guard these
    // windows panic in Debug/ReleaseSafe and are UB in ReleaseFast.
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    const leaf = try a.create(Node);
    leaf.* = .{ .pure = .{ .symbol = "x" } };

    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    defer diags.deinit(testing.allocator);

    const max = std.math.maxInt(i64);
    const min = std.math.minInt(i64);
    // Built field-wise, not via `Span.init` — these are the shapes that
    // reach the engine from a host that only checked `begin <= end`.
    const hostile = [_]Span{
        .{ .begin = max - 10, .end = max - 5 },
        .{ .begin = min, .end = 0 },
        .{ .begin = 0, .end = Pattern.MAX_TICK + 1 },
        .{ .begin = -Pattern.MAX_TICK - 1, .end = 0 },
    };
    for (hostile) |w| {
        try testing.expectError(
            error.TickOverflow,
            query(&arena_inst, testing.allocator, leaf, w, 0, &diags),
        );
    }

    // …and an ordinary in-range window is untouched by the guard.
    const ok = try query(&arena_inst, testing.allocator, leaf, Span.init(0, PPC), 0, &diags);
    try testing.expect(ok.len > 0);
}

test "resultToText: an extreme float hap value does not overflow its buffer" {
    // A `(pure <expr>)` leaf can evaluate to any f64, and `{d}` renders
    // full decimal notation — 310 characters for the largest finite value,
    // 326 for the smallest denormal. The old [64]u8 turned this renderer's
    // `catch unreachable` into a panic on a legitimate pattern.
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    const leaf = try a.create(Node);
    leaf.* = .{ .pure = .{ .number = std.math.floatMax(f64) } };

    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    defer diags.deinit(testing.allocator);
    const haps = try query(&arena_inst, testing.allocator, leaf, Span.init(0, PPC), 0, &diags);

    const text = try resultToText(a, .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .haps = haps,
        .diagnostics = &.{},
        .dropped = 0,
    });
    try testing.expect(text.len > 300);
}

test "query: pathological nesting depth returns DepthExceeded" {
    // Build a Node chain deeper than the parser would ever allow, directly,
    // to exercise the query frame guard: 5000 nested identity scales.
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    const leaf = try a.create(Node);
    leaf.* = .{ .pure = .{ .symbol = "x" } };
    var cur: *const Node = leaf;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const n = try a.create(Node);
        n.* = .{ .scale = .{ .num = 1, .den = 1, .child = cur } };
        cur = n;
    }
    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    defer diags.deinit(testing.allocator);
    try testing.expectError(
        error.DepthExceeded,
        query(&arena_inst, testing.allocator, cur, Span.init(0, PPC), 0, &diags),
    );
}
