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
//! combinator and every bare atom is a literal. Which semantics a binary
//! entry gets is decided by the ENTRY, never by the env: the legacy
//! `queryBinary` / `queryBinaryWithBudget` are frozen and degrade an expr
//! leaf to `silence` (see `compileBinary`), while `queryBinaryWithEnv` /
//! `queryBinaryWithBudgetAndEnv` run the private eval compile — the leaf is
//! captured as an IR view and evaluated per cycle under the shadowing
//! pattern-locals (an outer env chains beneath them, null env included).
//!
//! **Serialization is hand-rolled.** The `(haps …)` writer below never calls
//! `Printer` and reads binary only through `BinaryCursor`, so the read-only
//! `sjon-binary.wasm` artifact can ship the pattern consumer without dragging
//! in the parser / printer / edit logic.
//!
//! The value vocabulary (`Hap` / `PatValue`), the bounded compile + query
//! walkers, the two front-ends (`compileTree` / `compileBinary` → shared
//! `Node`) — with the prepared entries (`PreparedBinary`) reusing
//! `compileTree` through `queryTreeFull` — the `(haps …)` serializer ↔
//! reconstructor round-trip, and the per-hap `Expr` leaf evaluator all live
//! here.

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
/// Ceiling on `(euclid n k …)` steps. `k` is user input cast to `usize`
/// for `bjorklund` (O(k) gpa memory) and the `k`-slot sequence (8·k arena
/// bytes) before the first memory-budget poll; on wasm32 `usize` is `u32`,
/// so an unbounded `k` also truncated — `(euclid 1 4294967297 bd)` became
/// one hap in the ReleaseSmall artifact and a panic natively. Past the
/// ceiling the form is silence, the same degradation every other
/// out-of-domain `euclid` argument gets; the TS parity host mirrors it.
pub const MAX_EUCLID_STEPS: i64 = 1 << 16;

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
    // SAFETY: an i64 prints in at most 20 characters, sign included.
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
            // SAFETY: a u64 prints in at most 20 digits.
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
    /// variant is emitted by `compileTree` and by nothing else: the LEGACY
    /// binary compile (`compileBinary`) still degrades an expr leaf to
    /// `silence` (the binary twin below is the private eval compile's
    /// product, consumed only through `queryBinaryWithEnv` /
    /// `queryBinaryWithBudgetAndEnv`). A per-cycle eval that errors or
    /// yields an uncoercible shape drops that hap (bumping `Result.dropped`),
    /// keeping output a clean `(haps …)`.
    pure_expr: Ast.NodeIndex,
    /// Binary twin of `pure_expr`: a form in pure-value position captured as
    /// IR identity — the iterator's `NodeView` plus the `payload_pos` the
    /// cursor sat at when the view was handed out (`NodeView` carries no
    /// position, and a view is valid only while the cursor is at the value
    /// payload, so both are required to re-enter the leaf). Emitted only by
    /// the private eval compile, and queryable only through the
    /// `*WithEnv` binary entries, which build the `BinCtx` (retained buffer
    /// copy + cursor + pool index) the per-cycle eval reads through — the
    /// leaf is re-entered against the RETAINED COPY, never the caller's
    /// bytes. The eval, drop, and diagnostic semantics are the tree path's.
    /// SAFETY (twin rule, binary side): a hand-built `pure_expr_bin` queried
    /// through an entry with no binary context is a contract violation,
    /// exactly like a hand-built `pure_expr` under a null `ctx.tree` — the
    /// arm unwraps the context as an asserted invariant.
    pure_expr_bin: struct { view: BinaryCursor.NodeView, payload_pos: u32 },
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

    /// Structural equality. Recurses through children. Expression leaves
    /// compare only within a path kind: `.pure_expr` (tree) vs
    /// `.pure_expr_bin` (binary) are deliberately never structurally equal —
    /// the cross-variant tag check returns false — and two `.pure_expr_bin`
    /// nodes compare as *identity* (view + payload position), which is not a
    /// value judgment. Tree ≡ binary for expression patterns is therefore
    /// BEHAVIORAL (haps + `(code, path)` diagnostics + `dropped`; pinned by
    /// `expectTreeEqBinaryEnv`), while literal patterns stay structural.
    pub fn eql(self: *const Node, other: *const Node) bool {
        if (std.meta.activeTag(self.*) != std.meta.activeTag(other.*)) return false;
        return switch (self.*) {
            .silence => true,
            .pure => self.pure.eql(other.pure),
            .pure_expr => self.pure_expr == other.pure_expr,
            .pure_expr_bin => |l| l.view.kind == other.pure_expr_bin.view.kind and
                l.view.tag == other.pure_expr_bin.view.tag and
                (l.view.span != null) == (other.pure_expr_bin.view.span != null) and
                l.view.leading_comment_count == other.pure_expr_bin.view.leading_comment_count and
                l.payload_pos == other.pure_expr_bin.payload_pos,
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
/// `dropped` counts per-hap expression evaluations that failed at a *later*
/// cycle (eval error or uncoercible result) and so were silently omitted —
/// a domain hole, not a document defect. It is a non-diagnostic side channel
/// a host/editor can surface softly; it is **not** serialized into the
/// `(haps …)` wire text, so the dropped-hap set is pinned by the haps alone
/// (deterministic cross-host). Static defects, caught by the compile-time
/// dry-run, become diagnostics instead and never reach this counter. The
/// tree path counts `.pure_expr` drops; the `*WithEnv` binary entries count
/// `.pure_expr_bin` drops through the same channel; the frozen legacy
/// binary entries can still never bump it.
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
    if (k < 1 or n < 1 or n > k or k > MAX_EUCLID_STEPS) {
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
// Expr leaves, legacy vs eval: the LEGACY walk (`compileBinary`,
// mode `.legacy`) still has no expression identity — a form in `(pure …)`
// value position is a time *expression*, but the legacy walk never captures
// it and degrades the leaf to `silence` (where the tree path produces
// `pure_expr`). That is the one intentional divergence of the legacy
// entries; it is locked by a dedicated test, and the literal-atom
// `tree ≡ binary` property test excludes expression patterns. The EVAL walk
// (`compileBinaryEval`, mode `.eval`, private — no public
// `compileBinaryWithEnv`) adds the capture: the leaf's `NodeView` +
// payload position are recorded into `Node.pure_expr_bin`, dry-run at cycle
// 0 like the tree path, and the `*WithEnv` entries attach a `BinCtx` over a
// retained copy of the bytes so per-cycle evals re-enter the leaf.
// Re-uniting the paths through a materialized tree was declined by plan
// (§2 of the ask-29 pattern plan): the read-only artifact would need a
// `BinaryCursor`→`Ast` materializer, a second ownership layer.
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
///
/// LEGACY and frozen: this walk never produces `pure_expr` (an expr leaf
/// degrades to `silence`) and its behavior is byte-identical to the
/// pre-eval-mode walk — the entry, never the env, selects semantics, and
/// `queryBinary` / `queryBinaryWithBudget` keep this exact compile.
pub fn compileBinary(
    arena: Allocator,
    gpa: Allocator,
    bytes: []const u8,
    schema: Schema.Schema,
    diags: *std.ArrayList(Ast.Diagnostic),
) BinaryError!*const Node {
    _ = schema;
    _ = diags;
    return (try compileBinaryMode(arena, gpa, bytes, .{ .mode = .legacy })).node;
}

/// Which semantics a binary compile walk carries (plan §2.1: the entry,
/// never the env). `.legacy` is byte-identical to the historical walk;
/// `.eval` additionally captures `(pure <form>)` leaves as IR views.
const BinCompileMode = enum { legacy, eval };

/// Everything the decode walk needs beyond the frames, threaded from the
/// entry. The eval-only fields are null on the legacy walk (which discards
/// `schema`/`diags` exactly as `compileBinary` always has).
const BinCompileCtx = struct {
    mode: BinCompileMode,
    schema: Schema.Schema = Schema.Schema.init(&.{}),
    outer_env: ?*const Expr.Env = null,
    diags: ?*std.ArrayList(Ast.Diagnostic) = null,
    has_expr_leaf: ?*bool = null,
    /// `Budget.bytes` of the calling entry — the eval walk preflights its
    /// two arena-growing steps against it (checked; §2.5). Unused in legacy.
    bytes_budget: usize = 0,
    /// The entry's result arena, for capacity preflights (`queryCapacity`
    /// lives on the `ArenaAllocator`, not the child `Allocator`). Null on
    /// the legacy walk, which never preflights.
    arena_inst: ?*std.heap.ArenaAllocator = null,
};

/// One compiled binary walk: the node, the walk's pool index (arena-owned —
/// reused unchanged by the entry when it retains a copy, because the copy is
/// layout-identical), and whether any expr leaf was emitted (gates
/// retention + preflight for literal-only buffers).
const BinCompileResult = struct {
    node: *const Node,
    pool_index: []u32,
    has_expr_leaf: bool = false,
};

/// The shared binary decode walk behind `compileBinary` (`.legacy`) and
/// `compileBinaryEval` (`.eval`). Same frames, same cursor discipline, same
/// leniency; the only behavioral fork is the `pure` arm's form child.
fn compileBinaryMode(
    arena: Allocator,
    gpa: Allocator,
    bytes: []const u8,
    ctx: BinCompileCtx,
) BinaryError!BinCompileResult {
    var cursor = try BinaryCursor.Cursor.init(bytes);
    if (ctx.mode == .eval) {
        // Preflight (1) — the pool-index allocation below is an arena
        // growth: refuse BEFORE allocating when `4 * pool_count` bytes would
        // pass the byte budget (checked arithmetic; §2.5). The legacy walk
        // keeps its historical unchecked allocation.
        const pool_bytes = std.math.mul(usize, cursor.poolIndexLen(), @sizeOf(u32)) catch return error.MemoryBudgetExceeded;
        try preflightCapacity(ctx.arena_inst.?.queryCapacity(), pool_bytes, ctx.bytes_budget);
    }
    // Pool index for the compile walk, on the pattern arena: the decode
    // below reads a form head per node, which is O(pool entries) per
    // lookup without one. The arena owns it; no free to pair.
    const pool_index = try arena.alloc(u32, cursor.poolIndexLen());
    cursor.indexPools(pool_index);
    var roots = try cursor.rootIter();
    if (roots.remaining == 0) return .{ .node = try makeNode(arena, .silence), .pool_index = pool_index };
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
            .decode => |d| try binDecode(arena, gpa, &cursor, d.view, d.dest, &stack, &ctx),
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
    return .{ .node = result, .pool_index = pool_index, .has_expr_leaf = if (ctx.has_expr_leaf) |flag| flag.* else false };
}

/// The private eval compile (working name, plan §2.2 — deliberately NOT
/// public: privacy prevents obtaining a *valid* detached `pure_expr_bin`,
/// though `Node` being a public union means a hand-built one passed to an
/// entry with no binary context remains a contract violation guarded by the
/// SAFETY twin rule). Captures `(pure <form>)` leaves, dry-runs them at
/// cycle 0 (static failures become diagnostics + silence, tree parity), and
/// reports whether any leaf was emitted so the entry can skip retention and
/// the copy preflight for literal-only buffers (§2.5, O4).
fn compileBinaryEval(
    arena_inst: *std.heap.ArenaAllocator,
    gpa: Allocator,
    bytes: []const u8,
    schema: Schema.Schema,
    outer_env: ?*const Expr.Env,
    diags: *std.ArrayList(Ast.Diagnostic),
    budget: Budget,
) BinaryError!BinCompileResult {
    var has_expr_leaf = false;
    return compileBinaryMode(arena_inst.allocator(), gpa, bytes, .{
        .mode = .eval,
        .schema = schema,
        .outer_env = outer_env,
        .diags = diags,
        .has_expr_leaf = &has_expr_leaf,
        .bytes_budget = budget.bytes,
        .arena_inst = arena_inst,
    });
}

/// Checked `current + add` against a byte budget. Arithmetic overflow and
/// over-budget are both `MemoryBudgetExceeded` — the caller refuses BEFORE
/// the allocation it guards (§2.5's honest-preflight contract).
fn preflightCapacity(current: usize, add: usize, budget_bytes: usize) Error!void {
    const total = std.math.add(usize, current, add) catch return error.MemoryBudgetExceeded;
    if (total > budget_bytes) return error.MemoryBudgetExceeded;
}

fn binDecode(
    arena: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    view: BinaryCursor.NodeView,
    dest: **const Node,
    stack: *std.ArrayList(BinFrame),
    ctx: *const BinCompileCtx,
) BinaryError!void {
    switch (view.kind) {
        .form => try binDecodeForm(arena, gpa, cursor, view, dest, stack, ctx),
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
    ctx: *const BinCompileCtx,
) BinaryError!void {
    const fv = try BinaryCursor.readForm(cursor, view);
    var iter = fv.children;
    const head = fv.head;

    if (std.mem.eql(u8, head, "silence")) {
        try binDrain(cursor, iter);
        dest.* = try makeNode(arena, .silence);
    } else if (std.mem.eql(u8, head, "pure")) {
        // Exactly one positional leaf → pure; else silence (matches the tree
        // path's arity handling, minus the diagnostic — the legacy leniency).
        //
        // The form child is where the two modes fork (§2.8 — routing stays
        // narrow: only pure's DIRECT form child is an expression leaf):
        //  * `.legacy` — `binLeafValue` returns null for the form (as for
        //    any non-leaf shape) and the node becomes `silence`: the frozen
        //    divergence, locked by its dedicated test.
        //  * `.eval` — the leaf's `NodeView` + payload position are captured
        //    (`payload_pos` is read immediately: the cursor is at the value
        //    payload exactly when `iter.next()` hands the entry out), the
        //    body is skipped so the iteration continues, and after the loop
        //    the leaf is dry-run at cycle 0 like the tree path's `pure` arm.
        // A bare symbol / keyword stays a LITERAL in both modes (never
        // "helpfully" evaluated); a second positional stays silence.
        var positional_count: usize = 0;
        var val: ?PatValue = null;
        var expr: ?@FieldType(Node, "pure_expr_bin") = null;
        while (try iter.next()) |entry| {
            if (entry.kind == .positional) {
                positional_count += 1;
                if (positional_count == 1) {
                    if (ctx.mode == .eval and entry.value.kind == .form) {
                        expr = .{ .view = entry.value, .payload_pos = cursor.pos };
                        try BinaryCursor.skipBody(cursor, entry.value);
                    } else {
                        val = try binLeafValue(arena, cursor, entry.value);
                    }
                } else {
                    try BinaryCursor.skipBody(cursor, entry.value);
                }
            } else {
                try BinaryCursor.skipBody(cursor, entry.value);
            }
        }
        if (positional_count == 1) {
            if (expr) |e| {
                dest.* = try binPureExprLeaf(arena, gpa, cursor, ctx, e.view, e.payload_pos, head, fv.head_span);
            } else if (val) |v| {
                dest.* = try makeNode(arena, .{ .pure = v });
            } else {
                dest.* = try makeNode(arena, .silence);
            }
        } else {
            dest.* = try makeNode(arena, .silence);
        }
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
    if (k < 1 or n < 1 or n > k or k > MAX_EUCLID_STEPS) {
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
/// unit number), having skipped them. Note `form` is among them: in the
/// LEGACY walk a form in `(pure …)` value position degrades to `silence`
/// (the frozen divergence); the eval walk intercepts a direct form child
/// BEFORE reaching for this reader and captures it as an expr leaf instead —
/// every other form position (both modes) still lands here and is skipped.
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

/// Route one captured eval-mode expr leaf: dry-run it at cycle 0 / seed 0
/// (static validity is seed-independent, the tree path's rule), then either
/// emit the `pure_expr_bin` node or degrade to `silence` with the tree
/// path's exact diagnostic at path `[pure]`. The dry-run evaluates on a
/// VALUE COPY of the walk cursor (`evalBinaryView` repositions only `pos`,
/// and the copy shields the decode walk's iteration position entirely);
/// its transient scratch comes from `gpa`, once per leaf, never the arena —
/// so the dry-run cannot move the byte budget and the §2.5 preflights stay
/// the honest arbiter of arena growth.
fn binPureExprLeaf(
    arena: Allocator,
    gpa: Allocator,
    cursor: *const BinaryCursor.Cursor,
    ctx: *const BinCompileCtx,
    view: BinaryCursor.NodeView,
    payload_pos: u32,
    head: []const u8,
    head_span: ?Ast.Span,
) BinaryError!*const Node {
    const outcome = try dryRunLeafBinary(arena, gpa, cursor, view, payload_pos, ctx.schema, ctx.outer_env);
    switch (outcome) {
        .value => {
            if (ctx.has_expr_leaf) |flag| flag.* = true;
            return makeNode(arena, .{ .pure_expr_bin = .{ .view = view, .payload_pos = payload_pos } });
        },
        .eval_failed => |err| {
            const diags = ctx.diags.?;
            const msg = try std.fmt.allocPrint(arena, "(pure …) expression failed to evaluate at cycle 0: {s}", .{@errorName(err)});
            try diags.append(arena, try exprLeafDiagBin(arena, head, head_span, .pattern_value_eval_failed, msg));
            return makeNode(arena, .silence);
        },
        .result_invalid => {
            const diags = ctx.diags.?;
            try diags.append(arena, try exprLeafDiagBin(arena, head, head_span, .pattern_value_result_invalid, "(pure …) expression must yield a number / string / keyword / boolean / nil (a form result usually means a misspelled function name)"));
            return makeNode(arena, .silence);
        },
    }
}

/// Compile-time dry-run of one captured binary expr leaf at cycle 0 / seed
/// 0 — the binary twin of `dryRunLeaf`, reusing the SAME eval machinery the
/// per-cycle query will run (`evalBinaryView`), so dry-run acceptance and
/// per-hap semantics cannot drift. Channel mapping (plan §2.6, exactly):
///   * `.structural` — malformed wire under the capture propagates as the
///     typed `BinaryError`, even here at the dry-run; never a diagnostic.
///   * `.eval` — a static eval outcome (unbound name, depth/step/byte
///     ceiling, domain failure) → `eval_failed` → diagnostic + silence.
///   * `.host` — allocator-sourced; under the fixed scratch this is the
///     deterministic bounded-scratch exhaustion, which the tree dry-run
///     already maps to `eval_failed` (same diagnostic + silence — honoring
///     existing tree dry-run behavior for scratch OOM, not process OOM).
///   * `.multiple_roots` — the whole-buffer entry's framing error, never
///     raised by the view entry (asserted invariant).
fn dryRunLeafBinary(
    arena: Allocator,
    gpa: Allocator,
    cursor: *const BinaryCursor.Cursor,
    view: BinaryCursor.NodeView,
    payload_pos: u32,
    schema: Schema.Schema,
    outer_env: ?*const Expr.Env,
) BinaryError!LeafOutcome {
    const scratch_buf = try gpa.alloc(u8, PATTERN_EXPR_SCRATCH);
    defer gpa.free(scratch_buf);
    var fba = std.heap.FixedBufferAllocator.init(scratch_buf);
    const bindings = leafTimeBindings(0, 0);
    const env: Expr.Env = .{ .parent = outer_env, .bindings = &bindings };

    var dry_cursor = cursor.*; // value copy; `pos` is the only mutated field
    var source: Expr.BinaryFailureSource = .multiple_roots;
    var result = Expr.evalBinaryView(fba.allocator(), &dry_cursor, view, payload_pos, &env, schema, .{ .bytes = PATTERN_EXPR_BYTES }, &source) catch |err| {
        switch (source) {
            // Every structural member is a wire-decode name, all within this
            // module's BinaryError set (Expr's eval-only members never carry
            // the .structural tag) — @errorCast pins that contract.
            .structural => return @errorCast(err),
            .multiple_roots => unreachable,
            .eval, .host => return .{ .eval_failed = err },
        }
    };
    defer result.deinit();
    const pv = (try fromExprValue(arena, result.value)) orelse return .result_invalid;
    return .{ .value = pv };
}

/// The pattern-local time env every expr leaf evaluates under: `cycle` (f64
/// cycles), `tick` (i64 onset tick), `seed` (i64 query seed). Shared by the
/// tree leaf path, the binary leaf path, and both dry-runs, so the binding
/// vocabulary cannot drift between paths.
fn leafTimeBindings(cycle_tick: Tick, seed: i64) [3]Expr.Env.Binding {
    const cycle_f: f64 = @as(f64, @floatFromInt(cycle_tick)) / @as(f64, @floatFromInt(PPC));
    return .{
        .{ .name = "cycle", .value = .{ .number = cycle_f } },
        .{ .name = "tick", .value = .{ .integer_i64 = cycle_tick } },
        .{ .name = "seed", .value = .{ .integer_i64 = seed } },
    };
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

/// Binary twin of `exprLeafDiag` — identical message strings and path
/// `[pure]`; the head is borrowed from the pattern bytes (duped here). The
/// span falls back to the zero span when the buffer was compiled
/// span-stripped (the `Scale.span` precedent) — parity is asserted at
/// `(code, path)` granularity, which absorbs compact-vs-full span
/// differences.
fn exprLeafDiagBin(arena: Allocator, head: []const u8, head_span: ?Ast.Span, code: Ast.Diagnostic.Code, msg: []const u8) Error!Ast.Diagnostic {
    const head_copy = try arena.dupe(u8, head);
    const path = try arena.dupe([]const u8, &.{head_copy});
    return .{
        .span = head_span orelse .{ .start = 0, .end = 0 },
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
    /// `Budget.haps`, polled inside the per-cycle leaf loops: the walk's
    /// own poll runs once per frame, and a `pure` leaf over a 2^53-tick
    /// window emits 10^10 haps in one frame.
    haps_budget: usize,
    /// Host-provided outer env chained as the PARENT of every leaf eval's
    /// env: the pattern-locals `cycle`/`tick`/`seed` shadow it (an
    /// `Expr.Env` lookup searches own bindings before the parent), every
    /// other name falls through. Caller-owned; must outlive the query.
    outer_env: ?*const Expr.Env,
    /// Binary context for `.pure_expr_bin` leaves: the retained-copy cursor
    /// + pool index built by the `*WithEnv` entries. Null on the tree
    /// entries and the legacy binary entries — neither produces
    /// `pure_expr_bin` — so the arm unwraps it as an asserted invariant
    /// (the SAFETY twin rule, binary side).
    bin: ?BinCtx = null,
};

/// Outcome of evaluating one expression leaf (`.pure_expr` on the tree
/// path, `.pure_expr_bin` on the eval-capable binary entries) at one cycle.
/// The two failure arms are what the compile-time dry-run (cycle 0) turns
/// into the `pattern_value_eval_failed` / `pattern_value_result_invalid`
/// diagnostics, and what a later-cycle query turns into a counted drop —
/// one shared eval shape, so dry-run acceptance and per-hap semantics
/// cannot drift.
const LeafOutcome = union(enum) {
    /// Bridged successfully — a hap value.
    value: PatValue,
    /// `Expr` refused to evaluate: an unbound name, division by zero, an
    /// arity error, the step/depth/byte budget, or fixed-scratch exhaustion.
    /// Every member is deterministic in (expr, cycle, seed) — the scratch is
    /// a fixed buffer, so even `OutOfMemory` here is reproducible, not a host
    /// failure — so this drives a diagnostic (dry-run) or a clean drop.
    /// Carries the binary superset (`Expr.BinaryError`) because the binary
    /// leaf path lands here through the eval/`.host` channels; the
    /// structural channel never lands here (it propagates as `BinaryError`).
    eval_failed: Expr.BinaryError,
    /// Evaluated, but the result shape cannot be a hap value: a `form` (a
    /// misspelled / unresolved head yields a form literal, not an error), a
    /// vector, a date, or a time.
    result_invalid,
};

/// Binary context for the eval-capable entries (plan §2.2): the query's
/// retained copy of the pattern bytes with its own cursor, plus the
/// compile-time pool index (absolute `u32` offsets — reused unchanged
/// because the copy is layout-identical). Both live in Result-arena memory
/// (the cursor borrows the copy; the index IS arena memory), so they die
/// with the `Result` — the caller's bytes and env may be freed after the
/// call. Present iff the compiled pattern emitted at least one expr leaf.
const BinCtx = struct {
    cursor: BinaryCursor.Cursor,
    pool_index: []u32,
};

/// Query a compiled pattern over `window`, allocating the result haps in
/// `arena_inst` and appending any query-time diagnostics (e.g.
/// `pattern_tick_overflow`) to `diags` (arena-backed). Public
/// budget-defaulted form for a *pre-built* `Node` (no source tree) — used by
/// the depth test; cannot carry expression leaves: `pure_expr` needs a tree
/// and `pure_expr_bin` needs a binary context, neither of which this entry
/// receives, so it passes a null tree, an empty schema, and a throwaway drop
/// counter. SAFETY (twin rule): a caller-built `pure_expr` (no
/// `ctx.tree`) or `pure_expr_bin` (no `ctx.bin`) node here is a contract
/// violation; both engine arms unwrap their context as an asserted
/// invariant (`orelse unreachable`).
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
/// env of expression leaves (the literal-atom vocabulary remains
/// seed-independent). `tree` / `schema` back the tree-path `Expr` leaf
/// evaluator (null `tree` ⇒ the pattern provably has no `pure_expr`);
/// `outer_env` chains under every leaf's pattern-locals (see
/// `QueryCtx.outer_env`); `dropped` accumulates per-hap expr drops. There is
/// no `bin` parameter on the public surface: this entry can never evaluate a
/// `pure_expr_bin` leaf (see the SAFETY twin rule on `query`), and the
/// eval-capable binary entries reach the engine through the private
/// `queryWithBudgetInternal` instead.
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
    return queryWithBudgetInternal(arena_inst, gpa, node, window, seed, diags, budget, tree, schema, outer_env, dropped, null) catch |err| switch (err) {
        error.OutOfMemory,
        error.DepthExceeded,
        error.MemoryBudgetExceeded,
        error.HapBudgetExceeded,
        error.TickOverflow,
        => @errorCast(err),
        // `bin = null`: this entry can never evaluate a `.pure_expr_bin`
        // leaf, so no wire-decode error is reachable — the members above are
        // the whole reachable set (the SAFETY twin rule guards the arm that
        // would need a context); @errorCast pins that invariant (it panics
        // in Debug/ReleaseSafe if the impossible ever happens).
        else => unreachable,
    };
}

/// The one query-engine body every entry funnels through — `queryWithBudget`
/// (which forwards `bin = null`) and the eval-capable binary entries (which
/// pass their `BinCtx`). Identical walk, budgets, and polls as the
/// historical `queryWithBudget` body; `bin` only arms the `.pure_expr_bin`
/// engine arm. Returns the `BinaryError` superset because a binary leaf's
/// structural channel is a hard `BinaryError`; the null-bin wrapper maps
/// the unreachable members back to `Error`.
fn queryWithBudgetInternal(
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
    bin: ?BinCtx,
) BinaryError![]const Hap {
    // The one gate every query entry funnels through, so the walk below can
    // use unchecked tick arithmetic (see `Span.checkTickBounds`). Window
    // endpoints are user input; a window near the `i64` extremes would
    // otherwise overflow inside `CycleIterator.next`. Orientation is a
    // `Span` invariant, not user input: every entry that takes raw ticks
    // (`wasm.zig`, `wasm_binary.zig`, the CLI) rejects `begin > end`
    // before building the `Span`, and `Span.cycles` asserts it.
    try window.checkTickBounds();
    std.debug.assert(window.begin <= window.end);

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
    var ctx: QueryCtx = .{ .tree = tree, .schema = schema, .seed = seed, .scratch = &fba, .dropped = dropped, .outer_env = outer_env, .haps_budget = budget.haps, .bin = bin };

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
) BinaryError!void {
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
                if (out.items.len > ctx.haps_budget) return error.HapBudgetExceeded;
            }
        },
        .pure_expr => |expr_idx| {
            // One hap per cycle, but the value is `Expr`-evaluated per cycle
            // with `cycle`/`tick`/`seed` bound at the cycle onset. A later-
            // cycle eval error or uncoercible result is a domain hole: drop
            // the hap and bump the counter, leaving output a clean (haps …).
            // SAFETY: only `compileTree` emits `pure_expr` (the binary
            // compiler drains the leaf into `silence`), and every tree entry
            // sets `ctx.tree`; a caller-built `pure_expr` node under
            // `query()` with no tree is a contract violation.
            const tree = ctx.tree orelse unreachable;
            var it = span.cycles();
            while (it.next()) |piece| {
                const whole_begin = Pattern.cycleStart(piece.begin);
                const whole_end = try Pattern.checkedAdd(whole_begin, PPC);
                const whole = Span.init(whole_begin, whole_end);
                const part = whole.intersection(piece) orelse continue;
                switch (try evalLeaf(a, ctx, tree, expr_idx, whole_begin)) {
                    .value => |v| {
                        try out.append(gpa, .{ .timing = .{ .whole = whole, .part = part }, .value = v });
                        if (out.items.len > ctx.haps_budget) return error.HapBudgetExceeded;
                    },
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
        .pure_expr_bin => |leaf| {
            // Binary twin of the `.pure_expr` arm: one hap per cycle, the
            // value `Expr`-evaluated per cycle through the retained-copy
            // cursor. A later-cycle eval error or uncoercible result is a
            // domain hole (counted drop); malformed wire under the leaf is
            // a hard `BinaryError`; scratch exhaustion is a clean drop.
            // SAFETY: only the private eval compile emits `pure_expr_bin`,
            // and only the `queryBinaryWithEnv` / `queryBinaryWithBudgetAndEnv`
            // entries construct `ctx.bin`; a caller-built `pure_expr_bin`
            // node under an entry with no binary context is a contract
            // violation (the `.pure_expr`/`ctx.tree` twin rule, binary side).
            const bin = ctx.bin orelse unreachable;
            var it = span.cycles();
            while (it.next()) |piece| {
                const whole_begin = Pattern.cycleStart(piece.begin);
                const whole_end = try Pattern.checkedAdd(whole_begin, PPC);
                const whole = Span.init(whole_begin, whole_end);
                const part = whole.intersection(piece) orelse continue;
                switch (try evalLeafBinary(a, ctx, &bin, leaf, whole_begin)) {
                    .value => |v| {
                        try out.append(gpa, .{ .timing = .{ .whole = whole, .part = part }, .value = v });
                        if (out.items.len > ctx.haps_budget) return error.HapBudgetExceeded;
                    },
                    .eval_failed, .result_invalid => ctx.dropped.* += 1,
                }
            }
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
    const bindings = leafTimeBindings(cycle_tick, ctx.seed);
    const env: Expr.Env = .{ .parent = ctx.outer_env, .bindings = &bindings };

    ctx.scratch.reset();
    var result = Expr.evalWithRuntimeBudget(ctx.scratch.allocator(), tree, expr_idx, &env, ctx.schema, null, .{ .bytes = PATTERN_EXPR_BYTES }) catch |err| {
        return .{ .eval_failed = err };
    };
    defer result.deinit();
    const pv = (try fromExprValue(a, result.value)) orelse return .result_invalid;
    return .{ .value = pv };
}

/// Binary twin of `evalLeaf`: evaluate one captured `.pure_expr_bin` leaf
/// for the cycle whose onset tick is `cycle_tick`, through the SAME
/// machinery the dry-run ran (`Expr.evalBinaryView` over the shared fixed
/// scratch). The env is the pattern-locals over `ctx.outer_env` (shadow
/// rule identical to the tree path); the cursor is a VALUE COPY of the
/// retained-copy cursor (`evalBinaryView` repositions only `pos`, and no
/// query-walk state may move). Channel routing after a failed eval
/// (producer-side provenance — the out-param is the authority, the error
/// NAME is ambiguous by design):
///   * `.structural` — malformed wire under the leaf: hard `BinaryError`
///     (§2.6 bullets 1–2), never a drop.
///   * `.eval` — deterministic eval outcome after a good dry-run: a counted
///     drop (§2.6 bullet 4).
///   * `.host` — allocator-sourced; under the fixed scratch this is the
///     deterministic bounded-scratch exhaustion — a clean drop, not a
///     process OOM.
///   * `.multiple_roots` — never raised by the view entry (asserted).
fn evalLeafBinary(
    a: Allocator,
    ctx: *const QueryCtx,
    bin: *const BinCtx,
    leaf: @FieldType(Node, "pure_expr_bin"),
    cycle_tick: Tick,
) BinaryError!LeafOutcome {
    const bindings = leafTimeBindings(cycle_tick, ctx.seed);
    const env: Expr.Env = .{ .parent = ctx.outer_env, .bindings = &bindings };

    ctx.scratch.reset();
    var cursor = bin.cursor; // value copy; `pos` is the only mutated field
    var source: Expr.BinaryFailureSource = .multiple_roots;
    var result = Expr.evalBinaryView(ctx.scratch.allocator(), &cursor, leaf.view, leaf.payload_pos, &env, ctx.schema, .{ .bytes = PATTERN_EXPR_BYTES }, &source) catch |err| {
        switch (source) {
            // Same contract as the dry-run: structural members are wire
            // names within this module's BinaryError set.
            .structural => return @errorCast(err),
            .multiple_roots => unreachable,
            .eval, .host => return .{ .eval_failed = err },
        }
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
    const ctx: QueryCtx = .{ .tree = tree, .schema = schema, .seed = 0, .scratch = &fba, .dropped = &dropped, .outer_env = outer_env, .haps_budget = MAX_HAPS };
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
    // LEGACY and frozen: the binary path here has no `*Ast.Tree` and no
    // binary context, so it never produces or evaluates `pure_expr` /
    // `pure_expr_bin` (an expr leaf degrades to silence in the legacy
    // compile); `tree = null`, `bin = null`, and `dropped` stays 0.
    var dropped: usize = 0;
    const haps = try queryWithBudget(&arena_inst, gpa, node, window, seed, &diags, budget, null, schema, null, &dropped);

    return .{
        .arena = arena_inst,
        .haps = haps,
        .diagnostics = try diags.toOwnedSlice(a),
        .dropped = dropped,
    };
}

/// Binary-IR analogue of `queryTreeWithEnv` — the eval-capable entry. The
/// buffer is compiled by the PRIVATE eval compile (no public
/// `compileBinaryWithEnv`): `(pure <form>)` leaves are captured as IR views,
/// dry-run at cycle 0 (static failures become the tree path's diagnostics at
/// path `[pure]`, degrading that leaf to silence), and evaluated per cycle
/// under the pattern-locals `cycle` / `tick` / `seed`, which SHADOW
/// same-named outer bindings. `outer_env` (caller-owned) is chained as the
/// PARENT of every leaf in the dry-run and the per-hap eval alike; a null
/// env is exactly pattern-locals-only evaluation — tree parity pinned
/// in-repo — and is NOT the legacy entries' silent degradation: the ENTRY,
/// never the env, selects semantics.
///
/// If at least one expr leaf exists, the pattern bytes are copied into the
/// Result arena ONCE and one cursor + the compile-time pool index are
/// attached over the copy (layout-identical, so the index is reused); the
/// copy makes the Result self-contained — the caller's bytes AND the env
/// may be freed after the call. A literal-only buffer takes no copy, no
/// dry-run, and no arena growth beyond the legacy entries (§2.5/O4: pinned
/// by the bytes-tight-budget test). Two arena-growing steps are preflighted
/// with checked arithmetic against `budget.bytes` and refuse with
/// `MemoryBudgetExceeded` BEFORE allocating (the pool index, and the
/// retention copy); the historical post-compile check remains.
///
/// Errors: malformed wire anywhere is a hard `BinaryError` (the exact fuzz-
/// pinned set, unchanged); static eval defects are diagnostics; later-cycle
/// eval failures are counted drops — the tree path's three disjoint
/// channels, binary side.
///
/// SAFETY (twin rule): the compiled node is never exposed; a HAND-BUILT
/// `pure_expr_bin` node is only queryable through `query` / `queryWithBudget`
/// with a binary context they never receive — passing one there is a
/// contract violation guarded by the arm's `orelse unreachable`, exactly
/// like a hand-built `pure_expr` under a null tree.
pub fn queryBinaryWithEnv(
    gpa: Allocator,
    bytes: []const u8,
    schema: Schema.Schema,
    window: Span,
    seed: i64,
    outer_env: ?*const Expr.Env,
) BinaryError!Result {
    return queryBinaryWithBudgetAndEnv(gpa, bytes, schema, window, seed, .{}, outer_env);
}

/// Budget-parameterized `queryBinaryWithEnv` — the only budget+env one-shot
/// today. NOTE (owner-accepted asymmetry, plan §2.9/§6.2): the tree path has
/// no `WithBudgetAndEnv` twin (`queryTreeWithBudget` takes no env); this
/// entry is deliberately not mirrored. See `queryBinaryWithEnv` for the
/// full eval-mode contract.
pub fn queryBinaryWithBudgetAndEnv(
    gpa: Allocator,
    bytes: []const u8,
    schema: Schema.Schema,
    window: Span,
    seed: i64,
    budget: Budget,
    outer_env: ?*const Expr.Env,
) BinaryError!Result {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_inst.deinit();
    const a = arena_inst.allocator();

    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    const compiled = try compileBinaryEval(&arena_inst, gpa, bytes, schema, outer_env, &diags, budget);
    if (arena_inst.queryCapacity() > budget.bytes) return error.MemoryBudgetExceeded;

    // Retention: copy the bytes into the Result arena ONCE, iff at least one
    // expr leaf exists; then one `Cursor.init` + one `indexPools` over the
    // retained copy, reusing the compile-time pool index unchanged (the copy
    // is layout-identical). Preflight (2) refuses BEFORE the copy.
    var bin: ?BinCtx = null;
    if (compiled.has_expr_leaf) {
        try preflightCapacity(arena_inst.queryCapacity(), bytes.len, budget.bytes);
        const retained = try a.dupe(u8, bytes);
        var qcursor = try BinaryCursor.Cursor.init(retained);
        qcursor.indexPools(compiled.pool_index);
        bin = .{ .cursor = qcursor, .pool_index = compiled.pool_index };
    }

    var dropped: usize = 0;
    const haps = try queryWithBudgetInternal(&arena_inst, gpa, compiled.node, window, seed, &diags, budget, null, schema, outer_env, &dropped, bin);

    return .{
        .arena = arena_inst,
        .haps = haps,
        .diagnostics = try diags.toOwnedSlice(a),
        .dropped = dropped,
    };
}

/// Decoded, owned, self-contained prepared pattern: the tree owns its
/// strings; the caller's bytes may be freed once the decode that built the
/// tree returned. Query entries take `*const PreparedBinary` — the tree is
/// read-only at query (same envelope as sharing an `Ast.Tree` across
/// `queryTree*` calls today); all per-query state is call-local.
pub const PreparedBinary = struct {
    tree: Ast.Tree,
    /// null ⟺ the payload decoded to zero roots: queries answer silence
    /// (the shipped binary compile's empty→silence rule, :1103). There is
    /// no tree-path correspondent — `queryTreeFull` takes an explicit
    /// caller-selected root, and a rootless tree has none to select.
    root: ?Ast.NodeIndex,

    pub fn deinit(self: *PreparedBinary) void {
        self.tree.deinit();
    }

    /// Root discipline of the shipped binary compile (:1103-1104): more
    /// than one root is `error.MultipleRoots`; zero roots stores `null`.
    /// CONSUMES `tree` on success AND on error (freed internally on the
    /// error path) — after this call the caller's binding is dead either
    /// way; use `var prepared = try …fromTree(tree); defer prepared.deinit();`
    /// and never touch `tree` again.
    pub fn fromTree(tree: Ast.Tree) error{MultipleRoots}!PreparedBinary {
        if (tree.root.len > 1) {
            var t = tree;
            t.deinit();
            return error.MultipleRoots;
        }
        return .{ .tree = tree, .root = if (tree.root.len == 0) null else tree.root[0] };
    }
};

fn silenceResult(gpa: Allocator) Error!Result {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_inst.deinit();
    return .{ .arena = arena_inst, .haps = &.{}, .diagnostics = &.{}, .dropped = 0 };
}

/// The one body every `queryPreparedBinary*` entry forwards to: the zero-root
/// mapping, then the SAME `queryTreeFull` the tree entries use — the per-query
/// metered sequence is the tree path's own sequence by construction.
fn queryPreparedFull(
    gpa: Allocator,
    p: *const PreparedBinary,
    schema: Schema.Schema,
    window: Span,
    seed: i64,
    budget: Budget,
    outer_env: ?*const Expr.Env,
) Error!Result {
    const root = p.root orelse return silenceResult(gpa);
    return queryTreeFull(gpa, &p.tree, root, schema, window, seed, budget, outer_env);
}

/// Prepared-IR analogue of `queryTree`: query an owned, already-decoded
/// `PreparedBinary` (no per-call decode). A zero-root prepare (`root == null`)
/// answers the silence result. Budget-defaulted.
pub fn queryPreparedBinary(
    gpa: Allocator,
    p: *const PreparedBinary,
    schema: Schema.Schema,
    window: Span,
    seed: i64,
) Error!Result {
    return queryPreparedFull(gpa, p, schema, window, seed, .{}, null);
}

/// `queryPreparedBinary` with a host-provided outer `Expr.Env` — forwarded
/// live to the underlying `queryTreeFull` alongside the budget default,
/// never inspected by this entry (the entry, never the env, selects
/// semantics). A null env is exactly `queryPreparedBinary`.
pub fn queryPreparedBinaryWithEnv(
    gpa: Allocator,
    p: *const PreparedBinary,
    schema: Schema.Schema,
    window: Span,
    seed: i64,
    outer_env: ?*const Expr.Env,
) Error!Result {
    return queryPreparedFull(gpa, p, schema, window, seed, .{}, outer_env);
}

/// Budget-parameterized `queryPreparedBinary`.
pub fn queryPreparedBinaryWithBudget(
    gpa: Allocator,
    p: *const PreparedBinary,
    schema: Schema.Schema,
    window: Span,
    seed: i64,
    budget: Budget,
) Error!Result {
    return queryPreparedFull(gpa, p, schema, window, seed, budget, null);
}

/// The combined budget+env entry — real forwarding, not a doc promise: both
/// axes reach `queryTreeFull` simultaneously (the spike's pinned gap closes
/// here). This also fills the noted tree-side `WithBudgetAndEnv` asymmetry
/// (:2423-2427) for the prepared family without adding a tree entry.
pub fn queryPreparedBinaryWithBudgetAndEnv(
    gpa: Allocator,
    p: *const PreparedBinary,
    schema: Schema.Schema,
    window: Span,
    seed: i64,
    budget: Budget,
    outer_env: ?*const Expr.Env,
) Error!Result {
    return queryPreparedFull(gpa, p, schema, window, seed, budget, outer_env);
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

test "query: euclid steps past MAX_EUCLID_STEPS are silence, at the ceiling they play" {
    var r_over = try querySource(testing.allocator, "(euclid 3 65537 bd)", Span.init(0, PPC));
    defer r_over.deinit();
    try testing.expectEqual(@as(usize, 0), r_over.haps.len);

    var r_at = try querySource(testing.allocator, "(euclid 1 65536 bd)", Span.init(0, PPC));
    defer r_at.deinit();
    try testing.expectEqual(@as(usize, 1), r_at.haps.len);
}

test "query: a pure leaf over a huge window trips the hap budget inside the cycle loop" {
    // The walk polls the budget once per frame; a `pure` leaf emits one hap
    // per cycle *within* a frame, so a 2^53-tick window used to allocate
    // ~10^10 haps before the poll. A 1 MiB fixed buffer as the gpa makes the
    // old behaviour OutOfMemory; the in-loop poll returns HapBudgetExceeded
    // after `budget.haps + 1` haps.
    const Parser = @import("Parser.zig");
    const core = @import("plugins/core.zig");
    const pattern = @import("plugins/pattern.zig");
    const schema = Schema.Schema.init(&.{ core.plugin, pattern.plugin });
    var tree = try Parser.parse(testing.allocator, "bd");
    defer tree.deinit();
    var buf: [1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const window: Span = .{ .begin = 0, .end = 1_000_000 * PPC };
    try testing.expectError(error.HapBudgetExceeded, queryTreeWithBudget(fba.allocator(), &tree, tree.root[0], schema, window, 0, .{ .haps = 64 }));
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

// -- binary eval entries (queryBinaryWithEnv / queryBinaryWithBudgetAndEnv) -

/// Parse `src`, encode to binary IR (default preset), and query through the
/// eval-capable binary entry with an optional outer env — the new-entry twin
/// of `querySourceEnv`.
fn querySourceBinaryEnv(gpa: Allocator, src: [:0]const u8, window: Span, seed: i64, outer_env: ?*const Expr.Env) !Result {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    var bytes = try Binary.toBinary(gpa, tree, .{});
    defer bytes.deinit();
    return queryBinaryWithEnv(gpa, bytes.data, patternSchema(), window, seed, outer_env);
}

test "queryBinaryWithEnv: null env — pattern-locals eval gives 3 haps where legacy queryBinary gives 0" {
    // THE tracer: `(pure (+ cycle 0))` over three cycles. The legacy binary
    // entry (frozen) degrades the leaf to silence — 0 haps; the eval entry
    // evaluates it per cycle on the pattern-locals env alone: tree parity.
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const src: [:0]const u8 = "(pure (+ cycle 0))";
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    var bytes = try Binary.toBinary(testing.allocator, tree, .{});
    defer bytes.deinit();
    const window = Span.init(0, 3 * PPC);

    var legacy = try queryBinary(testing.allocator, bytes.data, patternSchema(), window, 0);
    defer legacy.deinit();
    try testing.expectEqual(@as(usize, 0), legacy.haps.len);
    try testing.expectEqual(@as(usize, 0), legacy.dropped);

    var r = try queryBinaryWithEnv(testing.allocator, bytes.data, patternSchema(), window, 0, null);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
    try testing.expectEqual(@as(usize, 0), r.dropped);
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = .{ .number = 0.0 } },
        .{ .timing = .{ .whole = Span.init(PPC, 2 * PPC), .part = Span.init(PPC, 2 * PPC) }, .value = .{ .number = 1.0 } },
        .{ .timing = .{ .whole = Span.init(2 * PPC, 3 * PPC), .part = Span.init(2 * PPC, 3 * PPC) }, .value = .{ .number = 2.0 } },
    });
}

test "queryBinaryWithEnv: outer bindings reach the leaf — dry-run and eval (base = 3 → 6)" {
    // Probe A's expression layer, binary side. `base` exists only in the
    // outer env: zero diagnostics means the env reached the cycle-0 dry-run
    // too (the null-env negative case is pinned by the typo-parity and
    // unbound-name tests below).
    const bindings = [_]Expr.Env.Binding{
        .{ .name = "base", .value = .{ .number = 3.0 } },
    };
    const env: Expr.Env = .{ .bindings = &bindings };
    var r = try querySourceBinaryEnv(testing.allocator, "(pure (* base 2))", Span.init(0, PPC), 0, &env);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
    try testing.expectEqual(@as(usize, 0), r.dropped);
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = .{ .number = 6.0 } },
    });
}

test "queryBinaryWithEnv: pattern-locals shadow the outer cycle/tick/seed decoys" {
    // Probe B, binary side: the outer env binds all three pattern-local names
    // to decoys; leaves still see the pattern's own cycle-onset bindings.
    // Queried over cycle 1 with seed 7 so every true value differs from its
    // decoy.
    const bindings = [_]Expr.Env.Binding{
        .{ .name = "cycle", .value = .{ .number = 99.0 } },
        .{ .name = "tick", .value = .{ .integer_i64 = -5 } },
        .{ .name = "seed", .value = .{ .integer_i64 = 1000 } },
    };
    const env: Expr.Env = .{ .bindings = &bindings };
    const third = @divExact(PPC, 3);
    var r = try querySourceBinaryEnv(
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

test "queryBinaryWithEnv: a control value reads through the env's parent scope" {
    // Probe C, binary side: `sway = 0.25` bound by the host, read as 0.5.
    const bindings = [_]Expr.Env.Binding{
        .{ .name = "sway", .value = .{ .number = 0.25 } },
    };
    const env: Expr.Env = .{ .bindings = &bindings };
    var r = try querySourceBinaryEnv(testing.allocator, "(pure (* sway 2))", Span.init(0, PPC), 0, &env);
    defer r.deinit();
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = .{ .number = 0.5 } },
    });
}

test "queryBinaryWithEnv: unbound name → pattern_value_eval_failed at [pure], 0 haps (error parity)" {
    // Probe E, binary side: a static defect becomes the same diagnostic the
    // tree path emits — never silence, never a drop.
    var r = try querySourceBinaryEnv(testing.allocator, "(pure (* absent 2))", Span.init(0, PPC), 0, null);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.pattern_value_eval_failed, r.diagnostics[0].code);
    try testing.expectEqual(@as(usize, 1), r.diagnostics[0].path.len);
    try testing.expectEqualStrings("pure", r.diagnostics[0].path[0]);
    try testing.expectEqual(@as(usize, 0), r.haps.len);
    try testing.expectEqual(@as(usize, 0), r.dropped);
}

test "queryBinaryWithEnv: a later-cycle eval failure is a counted drop (3 haps, dropped = 1)" {
    // Probe D, binary side: accepted at the cycle-0 dry-run, fails at cycle 2
    // (division by zero) — the hole is a counted drop on both paths.
    var r = try querySourceBinaryEnv(testing.allocator, "(pure (/ 1 (- cycle 2)))", Span.init(0, 4 * PPC), 0, null);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
    try testing.expectEqual(@as(usize, 1), r.dropped);
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = .{ .number = -0.5 } },
        .{ .timing = .{ .whole = Span.init(PPC, 2 * PPC), .part = Span.init(PPC, 2 * PPC) }, .value = .{ .number = -1.0 } },
        .{ .timing = .{ .whole = Span.init(3 * PPC, 4 * PPC), .part = Span.init(3 * PPC, 4 * PPC) }, .value = .{ .number = 1.0 } },
    });
}

test "queryBinaryWithBudgetAndEnv: haps = 1 returns HapBudgetExceeded on both paths (probe F)" {
    // The budget seam must see the same program on both paths: two haps would
    // be emitted, so haps = 1 refuses — not the legacy entry's silent 1-hap
    // success. The tree twin runs through compileTree + queryWithBudget (both
    // take the env); the binary side is the budget+env combo entry.
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const src: [:0]const u8 = "(stack (pure (* base 2)) (pure 3))";
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    const bindings = [_]Expr.Env.Binding{
        .{ .name = "base", .value = .{ .number = 3.0 } },
    };
    const env: Expr.Env = .{ .bindings = &bindings };

    {
        var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_inst.deinit();
        var diags: std.ArrayList(Ast.Diagnostic) = .empty;
        defer diags.deinit(testing.allocator);
        const node = try compileTree(arena_inst.allocator(), testing.allocator, &tree, tree.root[0], patternSchema(), &env, &diags);
        var dropped: usize = 0;
        try testing.expectError(
            error.HapBudgetExceeded,
            queryWithBudget(&arena_inst, testing.allocator, node, Span.init(0, PPC), 0, &diags, .{ .haps = 1 }, &tree, patternSchema(), &env, &dropped),
        );
    }

    var bytes = try Binary.toBinary(testing.allocator, tree, .{});
    defer bytes.deinit();
    try testing.expectError(
        error.HapBudgetExceeded,
        queryBinaryWithBudgetAndEnv(testing.allocator, bytes.data, patternSchema(), Span.init(0, PPC), 0, .{ .haps = 1 }, &env),
    );
}

test "compileBinaryEval: a (pure <form>) leaf compiles to pure_expr_bin; the legacy compile stays silence (same-module)" {
    // Probe G, both sides: the private eval compile captures the leaf as an
    // IR view + payload position and reports it; the legacy compile on the
    // same bytes still degrades to silence (frozen). Same-module access to
    // the private compile is the point of this test's location. The leaf is
    // self-contained (`(+ 1 2)`, no env needed) so the dry-run accepts it.
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const src: [:0]const u8 = "(pure (+ 1 2))";
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    var bytes = try Binary.toBinary(testing.allocator, tree, .{});
    defer bytes.deinit();
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    defer diags.deinit(testing.allocator);

    const compiled = try compileBinaryEval(&arena_inst, testing.allocator, bytes.data, patternSchema(), null, &diags, .{});
    try testing.expectEqual(std.meta.Tag(Node).pure_expr_bin, std.meta.activeTag(compiled.node.*));
    try testing.expect(compiled.has_expr_leaf);
    try testing.expectEqual(@as(usize, 0), diags.items.len);

    const legacy = try compileBinary(arena_inst.allocator(), testing.allocator, bytes.data, patternSchema(), &diags);
    try testing.expectEqual(std.meta.Tag(Node).silence, std.meta.activeTag(legacy.*));
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "binary eval routing: bare symbol and keyword stay literals; vector child and combinator typo stay silence (both paths)" {
    // §2.8 rows: only pure's direct FORM child is an expression. `(pure
    // sway)` is the literal symbol even though `sway` is bound in the env;
    // `(pure :kw)` is a literal keyword (NOT silence — keyword maps to
    // keyword on both leaf readers); a vector child is a non-leaf shape →
    // silence; a combinator typo keeps its silence. Every row asserts tree
    // and new-binary parity.
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const bindings = [_]Expr.Env.Binding{
        .{ .name = "sway", .value = .{ .number = 0.25 } },
    };
    const env: Expr.Env = .{ .bindings = &bindings };
    const window = Span.init(0, PPC);

    const rows = [_]struct { src: [:0]const u8, want: ?PatValue }{
        .{ .src = "(pure sway)", .want = sym("sway") },
        .{ .src = "(pure :kw)", .want = .{ .keyword = "kw" } },
        .{ .src = "(pure [1 2])", .want = null },
        .{ .src = "(pura 5)", .want = null },
    };
    inline for (rows) |row| {
        var tree = try Parser.parse(testing.allocator, row.src);
        defer tree.deinit();
        var tr = try queryTreeWithEnv(testing.allocator, &tree, tree.root[0], patternSchema(), window, 0, &env);
        defer tr.deinit();
        var bytes = try Binary.toBinary(testing.allocator, tree, .{});
        defer bytes.deinit();
        var br = try queryBinaryWithEnv(testing.allocator, bytes.data, patternSchema(), window, 0, &env);
        defer br.deinit();

        if (row.want) |w| {
            try expectHaps(tr, &.{.{ .timing = .{ .whole = window, .part = window }, .value = w }});
            try expectHaps(br, &.{.{ .timing = .{ .whole = window, .part = window }, .value = w }});
        } else {
            try testing.expectEqual(@as(usize, 0), tr.haps.len);
            try testing.expectEqual(@as(usize, 0), br.haps.len);
        }
    }
}

test "binary eval typo parity: (pure (bogusfn cycle)) → pattern_value_result_invalid at [pure] on both paths" {
    // A misspelled head evaluates to a form literal (not an error) — the
    // uncoercible result is the same static diagnostic on both paths.
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const src: [:0]const u8 = "(pure (bogusfn cycle))";
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    var tr = try queryTree(testing.allocator, &tree, tree.root[0], patternSchema(), Span.init(0, PPC), 0);
    defer tr.deinit();
    try testing.expectEqual(@as(usize, 1), tr.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.pattern_value_result_invalid, tr.diagnostics[0].code);
    try testing.expectEqualStrings("pure", tr.diagnostics[0].path[0]);

    var bytes = try Binary.toBinary(testing.allocator, tree, .{});
    defer bytes.deinit();
    var br = try queryBinaryWithEnv(testing.allocator, bytes.data, patternSchema(), Span.init(0, PPC), 0, null);
    defer br.deinit();
    try testing.expectEqual(@as(usize, 1), br.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.pattern_value_result_invalid, br.diagnostics[0].code);
    try testing.expectEqual(@as(usize, 1), br.diagnostics[0].path.len);
    try testing.expectEqualStrings("pure", br.diagnostics[0].path[0]);
    try testing.expectEqual(@as(usize, 0), br.haps.len);
}

test "binary eval entries: compact and full presets agree; span-stripped diagnostics carry the zero span" {
    // Compact (a pacer payload's profile) strips spans; full carries them.
    // Haps are identical; the unbound-name diagnostic is (code, path)-equal,
    // and the compact row's span is the zero-span fallback.
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const src: [:0]const u8 = "(stack (pure (+ cycle 0)) (pure 7))";
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const window = Span.init(0, 2 * PPC);

    var compact = try Binary.toBinary(testing.allocator, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer compact.deinit();
    var full = try Binary.toBinary(testing.allocator, tree, Binary.ToBinaryOptions.forMode(.full));
    defer full.deinit();

    var cr = try queryBinaryWithEnv(testing.allocator, compact.data, patternSchema(), window, 0, null);
    defer cr.deinit();
    var fr = try queryBinaryWithEnv(testing.allocator, full.data, patternSchema(), window, 0, null);
    defer fr.deinit();

    try testing.expectEqual(@as(usize, 0), cr.diagnostics.len);
    try testing.expectEqual(fr.haps.len, cr.haps.len);
    for (fr.haps, cr.haps) |f, c| try testing.expect(f.eql(c));

    // Zero-span fallback on the span-stripped buffer (probe E shape).
    const esrc: [:0]const u8 = "(pure (* absent 2))";
    var etree = try Parser.parse(testing.allocator, esrc);
    defer etree.deinit();
    var ecompact = try Binary.toBinary(testing.allocator, etree, Binary.ToBinaryOptions.forMode(.compact));
    defer ecompact.deinit();
    var efull = try Binary.toBinary(testing.allocator, etree, Binary.ToBinaryOptions.forMode(.full));
    defer efull.deinit();
    var ecr = try queryBinaryWithEnv(testing.allocator, ecompact.data, patternSchema(), Span.init(0, PPC), 0, null);
    defer ecr.deinit();
    var efr = try queryBinaryWithEnv(testing.allocator, efull.data, patternSchema(), Span.init(0, PPC), 0, null);
    defer efr.deinit();

    try testing.expectEqual(@as(usize, 1), ecr.diagnostics.len);
    try testing.expectEqual(efr.diagnostics[0].code, ecr.diagnostics[0].code);
    try testing.expectEqualStrings("pure", ecr.diagnostics[0].path[0]);
    // Zero-span fallback: `Diagnostic.span` is non-optional, and the
    // span-stripped buffer has no head span to carry.
    try testing.expectEqual(@as(i64, 0), ecr.diagnostics[0].span.start);
    try testing.expectEqual(@as(i64, 0), ecr.diagnostics[0].span.end);
}

test "binary eval entries: multiple expression leaves share one retained copy (mixed literal + expr stack)" {
    // Several captured leaves over one buffer: one retained copy, one cursor,
    // distinct payload positions — evaluated per cycle alongside literals.
    const window = Span.init(0, 2 * PPC);
    var r = try querySourceBinaryEnv(
        testing.allocator,
        "(stack (pure (+ cycle 0)) (pure (* cycle 2)) (pure 7) bd)",
        window,
        0,
        null,
    );
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
    try testing.expectEqual(@as(usize, 0), r.dropped);
    try testing.expectEqual(@as(usize, 8), r.haps.len);
    // Stack children complete in order (each fully, cycles ascending):
    // (pure (+ cycle 0)) → 0,1; (pure (* cycle 2)) → 0,2; (pure 7) → 7,7; bd.
    try testing.expect(r.haps[0].value.eql(.{ .number = 0.0 }));
    try testing.expect(r.haps[1].value.eql(.{ .number = 1.0 }));
    try testing.expect(r.haps[2].value.eql(.{ .number = 0.0 }));
    try testing.expect(r.haps[3].value.eql(.{ .number = 2.0 }));
    try testing.expect(r.haps[4].value.eql(.{ .integer_i64 = 7 }));
    try testing.expect(r.haps[5].value.eql(.{ .integer_i64 = 7 }));
    try testing.expect(r.haps[6].value.eql(sym("bd")));
    try testing.expect(r.haps[7].value.eql(sym("bd")));
}

/// Tree-vs-new-binary behavioral parity over one pattern: identical haps,
/// identical dropped count, identical `(code, path)` diagnostics. This is
/// the Phase A demonstration body (probes A–G) converted to target the new
/// entry and pinned green — the structural `Node.eql` property does not
/// apply to expression leaves; behavior does.
fn expectTreeEqBinaryEnv(gpa: Allocator, src: [:0]const u8, window: Span, outer_env: ?*const Expr.Env) !void {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");

    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    var tr = try queryTreeWithEnv(gpa, &tree, tree.root[0], patternSchema(), window, 0, outer_env);
    defer tr.deinit();

    var bytes = try Binary.toBinary(gpa, tree, .{});
    defer bytes.deinit();
    var br = try queryBinaryWithEnv(gpa, bytes.data, patternSchema(), window, 0, outer_env);
    defer br.deinit();

    try testing.expectEqual(tr.haps.len, br.haps.len);
    for (tr.haps, br.haps, 0..) |ta, ba, i| {
        if (!ta.eql(ba)) {
            std.debug.print("tree≡binary(env) hap {d} mismatch for `{s}`\n", .{ i, src });
            return error.TreeBinaryHapMismatch;
        }
    }
    try testing.expectEqual(tr.dropped, br.dropped);
    try testing.expectEqual(tr.diagnostics.len, br.diagnostics.len);
    for (tr.diagnostics, br.diagnostics) |ta, ba| {
        try testing.expectEqual(ta.code, ba.code);
        try testing.expectEqual(ta.path.len, ba.path.len);
        for (ta.path, ba.path) |pa, pb| try testing.expectEqualStrings(pa, pb);
    }
}

test "tree ≡ binary (behavioral): expression patterns through the eval entries" {
    // The expression corpus — happy, trig, seeded, domain-hole, static
    // defects, layered and nested — under the probe env (base/sway plus the
    // cycle/tick/seed decoys), over several windows. Structural tree≡binary
    // does not hold for expression leaves; behavioral parity does.
    const bindings = [_]Expr.Env.Binding{
        .{ .name = "base", .value = .{ .number = 3.0 } },
        .{ .name = "sway", .value = .{ .number = 0.25 } },
        .{ .name = "cycle", .value = .{ .number = 99.0 } },
        .{ .name = "tick", .value = .{ .integer_i64 = -5 } },
        .{ .name = "seed", .value = .{ .integer_i64 = 1000 } },
    };
    const env: Expr.Env = .{ .bindings = &bindings };
    const patterns = [_][:0]const u8{
        "(pure (+ 1 2))",
        "(pure (+ cycle 0))",
        "(pure (* 0.5 (+ 1 (sin (* (tau) cycle)))))",
        "(pure (rand01 seed cycle))",
        "(pure (/ 1 (- cycle 2)))",
        "(pure (+ nope 0))",
        "(pure (bogusfn cycle))",
        "(pure (vec2 1 2))",
        "(stack (pure (* base 2)) [0.1 0.2])",
        "[(pure (+ cycle 0)) (pure (+ tick 0)) (pure (+ seed 0))]",
        "(fast 2 (pure (* cycle 2)))",
        "(stack (pure (sin cycle)) bd)",
        "(stack (pure (* sway 2)) (pure 7))",
    };
    const windows = [_]Span{
        Span.init(0, PPC),
        Span.init(0, 4 * PPC),
        Span.init(-2 * PPC, 2 * PPC),
    };
    for (patterns) |src| {
        for (windows) |w| {
            try expectTreeEqBinaryEnv(testing.allocator, src, w, &env);
        }
    }
}

test "binary eval entries: the Result outlives the caller's bytes and env" {
    // Retention contract: the pattern bytes are copied into the Result arena
    // once (an expr leaf exists), so the caller may free the bytes AND the
    // env after the call — the haps read back identical afterwards.
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const src: [:0]const u8 = "(stack (pure (* base 2)) (pure 7))";
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    var bytes = try Binary.toBinary(testing.allocator, tree, .{});
    defer bytes.deinit();

    // The env lives in its own arena, deliberately freed before the asserts.
    var env_arena = std.heap.ArenaAllocator.init(testing.allocator);
    const ea = env_arena.allocator();
    const bindings = try ea.dupe(Expr.Env.Binding, &.{
        .{ .name = "base", .value = .{ .number = 3.0 } },
    });
    const env_ptr = try ea.create(Expr.Env);
    env_ptr.* = .{ .bindings = bindings };

    var r = try queryBinaryWithEnv(testing.allocator, bytes.data, patternSchema(), Span.init(0, PPC), 0, env_ptr);
    defer r.deinit();

    env_arena.deinit(); // the env is gone; the query no longer needs it

    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = .{ .number = 6.0 } },
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = .{ .integer_i64 = 7 } },
    });
}

test "binary eval entries: a literal-only pattern takes no retained copy (bytes-tight budget)" {
    // O4: literals are fully decoded into arena-owned PatValues at compile —
    // no bytes.len retention, no dry-run. A 50 KiB string literal under a
    // 100 KiB budget compiles and queries clean; a retained copy would push
    // the preflight (or the post-compile check) past the budget and fail
    // with MemoryBudgetExceeded.
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const literal_len = 50_000;
    const big = try testing.allocator.alloc(u8, literal_len);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const src = try std.fmt.allocPrintSentinel(testing.allocator, "(pure \"{s}\")", .{big}, 0);
    defer testing.allocator.free(src);
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    var bytes = try Binary.toBinary(testing.allocator, tree, .{});
    defer bytes.deinit();

    var r = try queryBinaryWithBudgetAndEnv(testing.allocator, bytes.data, patternSchema(), Span.init(0, PPC), 0, .{ .bytes = 100_000 }, null);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.haps.len);
    try testing.expect(r.haps[0].value == .string);
    try testing.expectEqualStrings(big, r.haps[0].value.string);
}

// ---------------------------------------------------------------------------
// §3.4 — adversarial wire / memory / offset tests over the eval entries.
// The hostile buffers are HAND-BUILT from the published wire layout
// (`src/Binary.zig`'s `//!` header: 16-byte header, LEB128 pool framing,
// tag byte + payload per node), so every structural expectation derives
// from the format constants — never from an encoder-produced fixture or an
// observed output. Each fixture names the channel that surfaces its defect
// (the compile walk's `skipBody` vs the cycle-0 dry-run's engine
// re-decode); the dry-run-surfaced member is the entry-level structural
// propagation the core review found uncovered.
// ---------------------------------------------------------------------------

const binfmt = @import("BinaryFormat.zig");

fn appendVarintTo(list: *std.ArrayList(u8), gpa: Allocator, v: u32) !void {
    var x = v;
    while (true) {
        const low: u8 = @intCast(x & 0x7F);
        x >>= 7;
        if (x == 0) {
            try list.append(gpa, low);
            return;
        }
        try list.append(gpa, low | 0x80);
    }
}

/// One hand-built wire per the published layout: `flags` verbatim, plain
/// string pool entries, then the root node stream (the builder writes the
/// root-count varint; `roots_body` is the node stream itself).
fn handWire(gpa: Allocator, flags: u8, pool_entries: []const []const u8, root_count: u32, roots_body: []const u8) ![]u8 {
    var pool_body: std.ArrayList(u8) = .empty;
    defer pool_body.deinit(gpa);
    for (pool_entries) |e| {
        try appendVarintTo(&pool_body, gpa, @intCast(e.len));
        try pool_body.appendSlice(gpa, e);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &binfmt.wire_magic);
    try out.append(gpa, binfmt.wire_version);
    try out.append(gpa, flags);
    try out.appendSlice(gpa, &.{ 0x00, 0x00 }); // reserved
    try out.appendSlice(gpa, &std.mem.toBytes(@as(u32, binfmt.HEADER_SIZE))); // pool_offset
    try out.appendSlice(gpa, &[_]u8{0} ** 4); // roots_offset, patched below
    try appendVarintTo(&out, gpa, @intCast(pool_entries.len));
    try appendVarintTo(&out, gpa, @intCast(pool_body.items.len));
    try out.appendSlice(gpa, pool_body.items);
    const roots_offset: u32 = @intCast(out.items.len);
    std.mem.writeInt(u32, out.items[12..16], roots_offset, .little);
    try appendVarintTo(&out, gpa, root_count);
    try out.appendSlice(gpa, roots_body);
    return out.toOwnedSlice(gpa);
}

fn wireNodeFormBare(gpa: Allocator, out: *std.ArrayList(u8), head_idx: u32, child_count: u32, children: []const u8) !void {
    try out.append(gpa, @intFromEnum(binfmt.Tag.form_bare));
    try appendVarintTo(out, gpa, head_idx);
    try appendVarintTo(out, gpa, child_count);
    try out.appendSlice(gpa, children);
}

fn wireNodeSymbol(gpa: Allocator, out: *std.ArrayList(u8), pool_idx: u32) !void {
    try out.append(gpa, @intFromEnum(binfmt.Tag.symbol));
    try appendVarintTo(out, gpa, pool_idx);
}

fn wireNodeI64(gpa: Allocator, out: *std.ArrayList(u8), v: i64) !void {
    try out.append(gpa, @intFromEnum(binfmt.Tag.number_i64));
    try out.appendSlice(gpa, &std.mem.toBytes(v));
}

fn wireChildPositional(gpa: Allocator, out: *std.ArrayList(u8), node: []const u8) !void {
    try out.append(gpa, @intFromEnum(binfmt.ChildTag.positional));
    try out.appendSlice(gpa, node);
}

test "binary eval entries: an out-of-range pool reference in a captured leaf's form head is the dry-run's hard structural error" {
    // The leaf's form-head pool index is out of range. The compile walk's
    // `skipBody` skips a head index WITHOUT resolving it, so the legacy
    // compile survives the same bytes (leaf degrades to silence, no
    // diagnostic) — which proves the malformed reference sits under the
    // capture and only the cycle-0 dry-run's engine re-decode reads it:
    // `readForm` resolves the head → `PoolIndexOutOfRange` → the §2.6
    // structural channel → the typed `BinaryError`, never a diagnostic.
    // This is the entry-level propagation pin (dry-run, not compile
    // skipBody) the core review found uncovered.
    const gpa = testing.allocator;
    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(gpa);
    var inner_children: std.ArrayList(u8) = .empty;
    defer inner_children.deinit(gpa);
    try wireNodeI64(gpa, &inner_children, 2);
    try wireChildPositional(gpa, &inner, inner_children.items);
    var leaf: std.ArrayList(u8) = .empty;
    defer leaf.deinit(gpa);
    // head_idx = 9, pool has exactly one entry ("pure") → out of range.
    try wireNodeFormBare(gpa, &leaf, 9, 1, inner.items);
    var roots: std.ArrayList(u8) = .empty;
    defer roots.deinit(gpa);
    // Root: `(pure <leaf>)` — the malformed head sits UNDER the capture.
    var leaf_entry: std.ArrayList(u8) = .empty;
    defer leaf_entry.deinit(gpa);
    try wireChildPositional(gpa, &leaf_entry, leaf.items);
    try wireNodeFormBare(gpa, &roots, 0, 1, leaf_entry.items);
    const bytes = try handWire(gpa, 0x00, &.{"pure"}, 1, roots.items);
    defer gpa.free(bytes);

    // The legacy entry survives: skipBody never resolves the head.
    var legacy = try queryBinary(gpa, bytes, patternSchema(), Span.init(0, PPC), 0);
    defer legacy.deinit();
    try testing.expectEqual(@as(usize, 0), legacy.haps.len);
    try testing.expectEqual(@as(usize, 0), legacy.diagnostics.len);

    // The eval entry's dry-run re-decodes the leaf → hard structural error.
    try testing.expectError(
        error.PoolIndexOutOfRange,
        queryBinaryWithEnv(gpa, bytes, patternSchema(), Span.init(0, PPC), 0, null),
    );
}

test "binary eval entries: a captured leaf's form at buffer end is a hard Truncated, never a diagnostic" {
    // The inner form declares two children the buffer does not carry. The
    // compile walk's skipBody reaches for the first declared child past the
    // buffer end → `Truncated` — a hard `BinaryError` from the entry
    // (compile-channel surface; the dry-run-surfaced member is pinned by
    // the pool-reference test above).
    const gpa = testing.allocator;
    var leaf: std.ArrayList(u8) = .empty;
    defer leaf.deinit(gpa);
    try wireNodeFormBare(gpa, &leaf, 1, 2, ""); // declares 2 children, carries none
    const bytes = try handWire(gpa, 0x00, &.{ "pure", "+" }, 1, leaf.items);
    defer gpa.free(bytes);
    try testing.expectError(
        error.Truncated,
        queryBinaryWithEnv(gpa, bytes, patternSchema(), Span.init(0, PPC), 0, null),
    );
}

test "binary eval entries: a truncated leaf span (head span cut at buffer end) is a hard Truncated" {
    // with_head_spans wire: the inner form's 8-byte head span runs past the
    // buffer end. skipBody's form arm reads the span first → `Truncated`.
    const gpa = testing.allocator;
    var roots: std.ArrayList(u8) = .empty;
    defer roots.deinit(gpa);
    var outer_children: std.ArrayList(u8) = .empty;
    defer outer_children.deinit(gpa);
    try outer_children.append(gpa, @intFromEnum(binfmt.ChildTag.positional));
    try outer_children.append(gpa, @intFromEnum(binfmt.Tag.form_bare));
    try outer_children.appendSlice(gpa, &.{ 0x10, 0x00, 0x00 }); // span: only 3 of 8 bytes
    try wireNodeFormBare(gpa, &roots, 0, 1, outer_children.items);
    const bytes = try handWire(gpa, binfmt.Flag.with_head_spans, &.{"pure"}, 1, roots.items);
    defer gpa.free(bytes);
    try testing.expectError(
        error.Truncated,
        queryBinaryWithEnv(gpa, bytes, patternSchema(), Span.init(0, PPC), 0, null),
    );
}

test "binary eval entries: a hostile decode-depth bomb under a captured leaf is a hard DepthExceeded" {
    // 2100 nested forms under the capture — past skipBody's skip-stack cap
    // (`MAX_TREE_DEPTH * 2` = 2048). The compile walk surfaces the hard
    // `DepthExceeded`; encoder-produced wire cannot reach this (legal
    // nesting ≤ 1024 admits exactly the 2048-frame skip stack).
    const gpa = testing.allocator;
    var node: std.ArrayList(u8) = .empty;
    defer node.deinit(gpa);
    try wireNodeI64(gpa, &node, 7);
    var i: usize = 0;
    while (i < 2100) : (i += 1) {
        var wrapped: std.ArrayList(u8) = .empty;
        defer wrapped.deinit(gpa);
        var children: std.ArrayList(u8) = .empty;
        defer children.deinit(gpa);
        try wireChildPositional(gpa, &children, node.items);
        try wireNodeFormBare(gpa, &wrapped, 0, 1, children.items);
        node.clearRetainingCapacity();
        try node.appendSlice(gpa, wrapped.items);
    }
    var leaf: std.ArrayList(u8) = .empty;
    defer leaf.deinit(gpa);
    var chain_entry: std.ArrayList(u8) = .empty;
    defer chain_entry.deinit(gpa);
    try wireChildPositional(gpa, &chain_entry, node.items);
    try wireNodeFormBare(gpa, &leaf, 0, 1, chain_entry.items); // head 0 = "pure"
    const bytes = try handWire(gpa, 0x00, &.{"pure"}, 1, leaf.items);
    defer gpa.free(bytes);
    try testing.expectError(
        error.DepthExceeded,
        queryBinaryWithEnv(gpa, bytes, patternSchema(), Span.init(0, PPC), 0, null),
    );
}

test "binary eval entries: a legal-nesting eval-depth bomb degrades to the tree path's dry-run diagnostic, tree-consistently" {
    // 800 nested `(+ 1 …)` forms: legal for the parser (MAX_PARSE_DEPTH
    // 1024) but past the eval frame ceiling (MAX_FRAMES 1024, ≈2 frames per
    // level). The eval channel — NOT the structural one — fires: the
    // cycle-0 dry-run emits `pattern_value_eval_failed` at `[pure]` and
    // degrades the leaf to silence on BOTH paths, identically. The oracle
    // is the tree path's published dry-run behavior; the binary entry must
    // match it (same machinery, same channel).
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    const depth = 800;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "(pure ");
    var i: usize = 0;
    while (i < depth) : (i += 1) try src.appendSlice(gpa, "(+ 1 ");
    try src.appendSlice(gpa, "7");
    i = 0;
    while (i < depth) : (i += 1) try src.appendSlice(gpa, ")");
    try src.appendSlice(gpa, ")");
    const src_z = try gpa.dupeZ(u8, src.items);
    defer gpa.free(src_z);
    var tree = try Parser.parse(gpa, src_z);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const window = Span.init(0, PPC);

    var tr = try queryTreeWithEnv(gpa, &tree, tree.root[0], patternSchema(), window, 0, null);
    defer tr.deinit();
    try testing.expectEqual(@as(usize, 1), tr.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.pattern_value_eval_failed, tr.diagnostics[0].code);
    try testing.expectEqualStrings("pure", tr.diagnostics[0].path[0]);
    try testing.expectEqual(@as(usize, 0), tr.haps.len);

    var bytes = try Binary.toBinary(gpa, tree, .{});
    defer bytes.deinit();
    var br = try queryBinaryWithEnv(gpa, bytes.data, patternSchema(), window, 0, null);
    defer br.deinit();
    try testing.expectEqual(@as(usize, 1), br.diagnostics.len);
    try testing.expectEqual(tr.diagnostics[0].code, br.diagnostics[0].code);
    try testing.expectEqualStrings("pure", br.diagnostics[0].path[0]);
    try testing.expectEqual(@as(usize, 0), br.haps.len);
}

test "binary eval entries: zero roots are silence; multiple roots are MultipleRoots (re-asserted on the eval entries)" {
    const gpa = testing.allocator;
    // Zero roots: a fully valid framing with an empty roots block.
    const zero = try handWire(gpa, 0x00, &.{}, 0, "");
    defer gpa.free(zero);
    var zr = try queryBinaryWithEnv(gpa, zero, patternSchema(), Span.init(0, PPC), 0, null);
    defer zr.deinit();
    try testing.expectEqual(@as(usize, 0), zr.haps.len);
    try testing.expectEqual(@as(usize, 0), zr.diagnostics.len);

    // Two roots: the framing error, still hard on the eval entry.
    var r2: std.ArrayList(u8) = .empty;
    defer r2.deinit(gpa);
    var s1: std.ArrayList(u8) = .empty;
    defer s1.deinit(gpa);
    var s2: std.ArrayList(u8) = .empty;
    defer s2.deinit(gpa);
    try wireNodeSymbol(gpa, &s1, 0);
    try wireNodeSymbol(gpa, &s2, 0);
    try r2.appendSlice(gpa, s1.items);
    try r2.appendSlice(gpa, s2.items);
    const multi = try handWire(gpa, 0x00, &.{"bd"}, 2, r2.items);
    defer gpa.free(multi);
    try testing.expectError(
        error.MultipleRoots,
        queryBinaryWithEnv(gpa, multi, patternSchema(), Span.init(0, PPC), 0, null),
    );
}

test "binary eval entries: the retention preflight charges exactly bytes.len — the query's exact footprint passes, one byte short of the copy refuses before it" {
    // Mechanism pin for the copy-once contract (not a timing claim). Two
    // fresh-arena probes learn the constants the entry itself computes:
    // C = the post-compile capacity (probe runs compileBinaryEval exactly
    // as the entry does), F = the finished query's total arena footprint
    // (probe runs the query under the default budget and reads the
    // Result's arena). Then:
    //   * budget = F — the query's exact total footprint, copy included —
    //     passes end to end (allocation is deterministic, so no poll ever
    //     sees more than F);
    //   * budget = C + bytes.len - 1 — everything but one byte of the
    //     retained copy — refuses with MemoryBudgetExceeded at preflight
    //     (2), BEFORE the copy. The failing site is unambiguous by
    //     arithmetic: preflight (1)'s charge (4·pool_count) and the
    //     post-compile check (capacity C) both fit this budget — the pool
    //     here is 4 entries (16 bytes) against a ~90-byte buffer — so the
    //     only check the budget can fail is the retention preflight.
    // The arena's chunked growth means `C + bytes.len` itself is NOT a
    // guaranteed pass (the dupe may open a fresh chunk); the exact-fit
    // member therefore pins the observed total footprint, not the
    // preflight arithmetic.
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    const src: [:0]const u8 = "(stack (pure (+ cycle 0)) (pure 7))";
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    var bytes = try Binary.toBinary(gpa, tree, .{});
    defer bytes.deinit();

    // Probe 1: post-compile capacity, and the leaf flag that gates the copy.
    var probe_arena = std.heap.ArenaAllocator.init(gpa);
    defer probe_arena.deinit();
    var probe_diags: std.ArrayList(Ast.Diagnostic) = .empty;
    defer probe_diags.deinit(gpa);
    const probe = try compileBinaryEval(&probe_arena, gpa, bytes.data, patternSchema(), null, &probe_diags, .{});
    try testing.expect(probe.has_expr_leaf);
    const capacity_after_compile = probe_arena.queryCapacity();

    // Probe 2: the finished query's exact total footprint.
    var foot = try queryBinaryWithBudgetAndEnv(gpa, bytes.data, patternSchema(), Span.init(0, PPC), 0, .{}, null);
    defer foot.deinit();
    try testing.expectEqual(@as(usize, 2), foot.haps.len);
    const exact_footprint = foot.arena.queryCapacity();

    // Exact fit: the whole observed footprint, copy included, passes.
    var ok = try queryBinaryWithBudgetAndEnv(gpa, bytes.data, patternSchema(), Span.init(0, PPC), 0, .{ .bytes = exact_footprint }, null);
    defer ok.deinit();
    try testing.expectEqual(@as(usize, 2), ok.haps.len);
    try testing.expectEqual(@as(usize, 0), ok.diagnostics.len);

    // One byte short of the copy: preflight (2) refuses before it.
    try testing.expectError(
        error.MemoryBudgetExceeded,
        queryBinaryWithBudgetAndEnv(
            gpa,
            bytes.data,
            patternSchema(),
            Span.init(0, PPC),
            0,
            .{ .bytes = capacity_after_compile + bytes.data.len - 1 },
            null,
        ),
    );
}

test "binary eval entries: the caller may scribble and free the bytes and free the env after the call" {
    // The caller-side lifetime contract: after the call returns, neither
    // the caller's bytes nor the env is read again — scribbling the bytes
    // and freeing both before reading the Result is safe. The MECHANISM
    // that makes this true (the copy is taken and charged iff a leaf
    // exists) is pinned by the exact-fit test above and the literal-only
    // bytes-tight test below; this test pins the observable caller side.
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    const src: [:0]const u8 = "(stack (pure (* base 2)) (pure 7))";
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    var bytes = try Binary.toBinary(gpa, tree, .{});
    defer bytes.deinit();

    // The caller's bytes are an owned copy we control, and the env lives
    // in its own arena.
    const caller_bytes = try gpa.dupe(u8, bytes.data);
    defer gpa.free(caller_bytes);
    var env_arena = std.heap.ArenaAllocator.init(gpa);
    const ea = env_arena.allocator();
    const bindings = try ea.dupe(Expr.Env.Binding, &.{
        .{ .name = "base", .value = .{ .number = 3.0 } },
    });
    const env_ptr = try ea.create(Expr.Env);
    env_ptr.* = .{ .bindings = bindings };

    var r = try queryBinaryWithEnv(gpa, caller_bytes, patternSchema(), Span.init(0, PPC), 0, env_ptr);

    // Both caller-owned inputs are gone before any Result read.
    env_arena.deinit();
    @memset(caller_bytes, 0xAA);

    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
    try expectHaps(r, &.{
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = .{ .number = 6.0 } },
        .{ .timing = .{ .whole = Span.init(0, PPC), .part = Span.init(0, PPC) }, .value = .{ .integer_i64 = 7 } },
    });
}

test "binary eval entries: seed variation moves the seeded leaf identically on both paths" {
    // `(rand01 seed cycle)` under seeds 0 and 7: the hap lists differ
    // between seeds (the variation is observable), and tree ≡ binary at
    // each seed — the pattern-local `seed` binding rides the same env on
    // both paths.
    const gpa = testing.allocator;
    var by_seed: [2]Result = undefined;
    var tree_by_seed: [2]Result = undefined;
    const seeds = [_]i64{ 0, 7 };
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const src: [:0]const u8 = "(pure (rand01 seed cycle))";
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    var bytes = try Binary.toBinary(gpa, tree, .{});
    defer bytes.deinit();
    const window = Span.init(0, 2 * PPC);
    for (seeds, 0..) |s, i| {
        tree_by_seed[i] = try queryTreeWithEnv(gpa, &tree, tree.root[0], patternSchema(), window, s, null);
        by_seed[i] = try queryBinaryWithEnv(gpa, bytes.data, patternSchema(), window, s, null);
    }
    defer for (0..seeds.len) |i| {
        tree_by_seed[i].deinit();
        by_seed[i].deinit();
    };
    // Per-seed parity, hap for hap.
    for (seeds, 0..) |_, i| {
        try testing.expectEqual(tree_by_seed[i].haps.len, by_seed[i].haps.len);
        try testing.expectEqual(@as(usize, 2), by_seed[i].haps.len);
        for (tree_by_seed[i].haps, by_seed[i].haps) |t, b| {
            try testing.expect(t.eql(b));
        }
    }
    // The variation is real: seed 7's values differ from seed 0's.
    var any_different = false;
    for (by_seed[0].haps, by_seed[1].haps) |a, b| {
        if (!a.value.eql(b.value)) any_different = true;
    }
    try testing.expect(any_different);
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

// -- prepared (PreparedBinary / queryPreparedBinary*) — ask 30 / M4 D2 -------

// Container-level const: static lifetime. (A function-local array returned by
// reference would dangle once the frame dies — the helper's original shape was
// malformed; fix-pass 2026-10-21.)
const bindings_base3 = [_]Expr.Env.Binding{
    .{ .name = "base", .value = .{ .number = 3.0 } },
    .{ .name = "sway", .value = .{ .number = 0.25 } },
    .{ .name = "cycle", .value = .{ .number = 99.0 } },
    .{ .name = "tick", .value = .{ .integer_i64 = -5 } },
    .{ .name = "seed", .value = .{ .integer_i64 = 1000 } },
};

fn testEnvBase3() Expr.Env {
    // the intake env verbatim (base=3), incl. the shadow decoys that must lose
    // to the pattern-locals cycle/tick/seed
    return .{ .bindings = &bindings_base3 };
}

/// Structural outcome equality: haps (count, timing, PatValue bit-exact),
/// dropped, diagnostics (code + path + ORDER). Spans deliberately excluded
/// (compact profile carries none; span content was never a parity axis).
fn expectSameOutcome(t: *const Result, p: *const Result) !void {
    try testing.expectEqual(t.dropped, p.dropped);
    try testing.expectEqual(t.haps.len, p.haps.len);
    for (t.haps, p.haps) |th, ph| {
        try testing.expect(th.value.eql(ph.value)); // PatValue.eql — raw f64 bits, byte-exact slices, tag match
        try testing.expectEqual(th.timing.part.begin, ph.timing.part.begin);
        try testing.expectEqual(th.timing.part.end, ph.timing.part.end);
        try testing.expectEqual(th.timing.whole != null, ph.timing.whole != null);
        if (th.timing.whole) |wh| {
            try testing.expectEqual(wh.begin, ph.timing.whole.?.begin);
            try testing.expectEqual(wh.end, ph.timing.whole.?.end);
        }
    }
    try testing.expectEqual(t.diagnostics.len, p.diagnostics.len);
    for (t.diagnostics, p.diagnostics, 0..) |td, pd, i| {
        errdefer std.debug.print("diag {d}: text={s} prepared={s}\n", .{ i, @tagName(td.code), @tagName(pd.code) });
        try testing.expectEqual(td.code, pd.code);
        try testing.expectEqual(td.path.len, pd.path.len);
        for (td.path, pd.path) |ts, ps| try testing.expectEqualStrings(ts, ps);
    }
}

test "prepared: root discipline — multi-root refuses at fromTree (typed, leak-free), zero-root queries as silence" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    // multi-root: fromTree refuses; the consumed tree is freed internally (testing.allocator fails on leak)
    {
        var tree = try Parser.parse(gpa, "1 2");
        defer tree.deinit();
        var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
        defer bytes.deinit();
        const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
        try testing.expectError(error.MultipleRoots, PreparedBinary.fromTree(decoded)); // decoded consumed+freed inside
    }
    // zero-root: prepare succeeds, every entry answers the silence shape
    {
        var tree = try Parser.parse(gpa, "");
        defer tree.deinit();
        var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
        defer bytes.deinit();
        const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
        var p = try PreparedBinary.fromTree(decoded);
        defer p.deinit();
        const schema = patternSchema();
        var r = try queryPreparedBinaryWithBudgetAndEnv(gpa, &p, schema, Span.init(0, PPC), 0, .{}, null);
        defer r.deinit();
        try testing.expectEqual(@as(usize, 0), r.haps.len);
        try testing.expectEqual(@as(usize, 0), r.dropped);
        try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
    }
}

test "prepared: single-root query ≡ tree path (the identity smoke pin)" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    var tree = try Parser.parse(gpa, "(cat \"alpha\" (pure (* base 2)))");
    defer tree.deinit();
    var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bytes.deinit();
    const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
    var p = try PreparedBinary.fromTree(decoded);
    defer p.deinit();
    const env = testEnvBase3();
    var rp = try queryPreparedBinaryWithEnv(gpa, &p, patternSchema(), Span.init(0, 4 * PPC), 0, &env);
    defer rp.deinit();
    var rt = try queryTreeWithEnv(gpa, &tree, tree.root[0], patternSchema(), Span.init(0, 4 * PPC), 0, &env);
    defer rt.deinit();
    try expectSameOutcome(&rt, &rp); // helper below — haps/dropped/diags, not just counts
}

// -- prepared battery — ask 30 / M4 D3 (T-PARITY + T-FLOORS) -----------------
//
// The fixture builders below are the plan's requirement of record
// (docs/plans/asks/30-validation/plan.md, D3 Step 1), ported from the executed
// spike runner (.agent/control/ask30/spike/spike30-runner.zig:60-140 — ignored
// `.agent/` history: provenance, not a runtime dependency). Everything in this
// region is source-owned and portable.

// ---- battery fixture builders (ported from spike30-runner.zig:60-140) ----
const ballast_strings = 24;
const ballast_a_run = 4088;
const pool_rich_count = 2048;
const dense_leaves = 16;

fn buildBallastSource(gpa: Allocator, with_expr_leaf: bool) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "(cat (pure 0.5)");
    for (0..ballast_strings) |i| {
        var idx: [16]u8 = undefined;
        const digits = try std.fmt.bufPrint(&idx, "{d:0>8}", .{i});
        try buf.appendSlice(gpa, " \"");
        try buf.appendSlice(gpa, digits);
        for (0..ballast_a_run) |_| try buf.append(gpa, 'a');
        try buf.appendSlice(gpa, "\"");
    }
    if (with_expr_leaf) try buf.appendSlice(gpa, " (pure (+ 1 2))");
    try buf.appendSlice(gpa, ")");
    try buf.append(gpa, 0);
    const all = try buf.toOwnedSlice(gpa);
    return all[0 .. all.len - 1 :0];
}

fn buildPoolRichSource(gpa: Allocator, count: usize) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    // nested cats: a flat 2049-child form exceeds MAX_COMPILE_FRAMES (1024);
    // 512-wide chunks keep the walk ~514 frames deep — payload content unchanged
    try buf.appendSlice(gpa, "(cat (pure 0.5)");
    var i: usize = 0;
    while (i < count) : (i += 512) {
        const end = @min(i + 512, count);
        try buf.appendSlice(gpa, " (cat");
        var j: usize = i;
        while (j < end) : (j += 1) {
            var idx: [24]u8 = undefined;
            const digits = try std.fmt.bufPrint(&idx, " \"q{d:0>4}\"", .{j});
            try buf.appendSlice(gpa, digits);
        }
        try buf.appendSlice(gpa, ")");
    }
    try buf.appendSlice(gpa, ")");
    try buf.append(gpa, 0);
    const all = try buf.toOwnedSlice(gpa);
    return all[0 .. all.len - 1 :0];
}

fn buildDenseExprSource(gpa: Allocator) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "(cat");
    for (0..dense_leaves) |_| try buf.appendSlice(gpa, " (pure (+ 1 2))");
    try buf.appendSlice(gpa, ")");
    try buf.append(gpa, 0);
    const all = try buf.toOwnedSlice(gpa);
    return all[0 .. all.len - 1 :0];
}

fn buildMixedAlignmentSource(gpa: Allocator) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    const sizes = [_]usize{ 1, 7, 24, 63, 64, 4096 };
    try buf.appendSlice(gpa, "(cat");
    for (sizes) |n| {
        try buf.appendSlice(gpa, " \"");
        for (0..n) |_| try buf.append(gpa, 's');
        try buf.appendSlice(gpa, "\" (pure (/ 1 base)) (pure (+ base 1))");
    }
    try buf.appendSlice(gpa, ")");
    try buf.append(gpa, 0);
    const all = try buf.toOwnedSlice(gpa);
    return all[0 .. all.len - 1 :0];
}

/// One battery point: run prepared vs the text oracle and assert full outcome
/// equality; run the legacy one-shot and RECORD its outcome (never asserted —
/// its pre-existing multi-leaf order gap is documented, A.7).
fn checkPoint(
    gpa: Allocator,
    tree: *const Ast.Tree,
    p: *const PreparedBinary,
    bytes: []const u8,
    window: Span,
    seed: i64,
    env: ?*const Expr.Env,
) !void {
    var rt = try queryTreeWithEnv(gpa, tree, tree.root[0], patternSchema(), window, seed, env);
    defer rt.deinit();
    var rp = try queryPreparedBinaryWithEnv(gpa, p, patternSchema(), window, seed, env);
    defer rp.deinit();
    try expectSameOutcome(&rt, &rp);
    // one-shot arm: record-only (never asserted, never propagated) — its
    // pre-existing multi-leaf order gap / floors divergence is documented (A.7).
    if (queryBinaryWithBudgetAndEnv(gpa, bytes, patternSchema(), window, seed, .{}, env)) |res| {
        var ro = res;
        defer ro.deinit();
        std.debug.print("  [recorded] one-shot haps={d} dropped={d} diags={d}\n", .{ ro.haps.len, ro.dropped, ro.diagnostics.len });
    } else |e| {
        std.debug.print("  [recorded] one-shot error: {s}\n", .{@errorName(e)});
    }
}

/// Coverage is COUNTED, never copied from a report: the wrapper bumps a
/// caller-owned counter for every executed comparison point, and the battery
/// asserts the executed total against the sum declared by the case table.
fn checkPointCounted(
    gpa: Allocator,
    tree: *const Ast.Tree,
    p: *const PreparedBinary,
    bytes: []const u8,
    window: Span,
    seed: i64,
    env: ?*const Expr.Env,
    executed: *usize,
) !void {
    executed.* += 1;
    return checkPoint(gpa, tree, p, bytes, window, seed, env);
}

test "prepared: three-way parity battery (text oracle ≡ prepared at every executed point)" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    const env3 = testEnvBase3();
    const bind2 = [_]Expr.Env.Binding{.{ .name = "base", .value = .{ .number = 2.0 } }};
    const env2: Expr.Env = .{ .bindings = &bind2 };
    const bind1 = [_]Expr.Env.Binding{.{ .name = "base", .value = .{ .number = 1.0 } }};
    const env1: Expr.Env = .{ .bindings = &bind1 };
    const bind0 = [_]Expr.Env.Binding{.{ .name = "base", .value = .{ .number = 0.0 } }};
    const env0: Expr.Env = .{ .bindings = &bind0 };
    const bindmiss = [_]Expr.Env.Binding{.{ .name = "sway", .value = .{ .number = 0.25 } }};
    const envmiss: Expr.Env = .{ .bindings = &bindmiss };
    const bindextra = [_]Expr.Env.Binding{
        .{ .name = "base", .value = .{ .number = 3.0 } },
        .{ .name = "unrelated", .value = .{ .number = 7.0 } },
    };
    const envextra: Expr.Env = .{ .bindings = &bindextra };
    const cyc0 = Span.init(0, PPC);
    const cyc4 = Span.init(0, 4 * PPC);

    // The 11 executed fixtures (sources exactly as executed, runner :403-415),
    // each with its executed (env, window, seed) points — 32 carried points:
    const a_src = try buildBallastSource(gpa, true);
    defer gpa.free(a_src);
    const b_src = try buildBallastSource(gpa, false);
    defer gpa.free(b_src);
    const c_src = try buildPoolRichSource(gpa, pool_rich_count);
    defer gpa.free(c_src);
    const d_src = try buildDenseExprSource(gpa);
    defer gpa.free(d_src);
    const e_src = try buildMixedAlignmentSource(gpa);
    defer gpa.free(e_src);
    const Point = struct { env: ?*const Expr.Env, window: Span, seed: i64 = 0 };
    const Case = struct { label: []const u8, src: [:0]const u8, points: []const Point };
    const cases = [_]Case{
        .{ .label = "a-repro-a-exact", .src = a_src, .points = &.{.{ .env = &env3, .window = cyc0 }} },
        .{ .label = "b-literal-twin", .src = b_src, .points = &.{.{ .env = &env3, .window = cyc0 }} },
        .{ .label = "c-pool-rich-2048", .src = c_src, .points = &.{.{ .env = &env3, .window = cyc0 }} },
        .{ .label = "d-dense-expr", .src = d_src, .points = &.{.{ .env = &env3, .window = cyc0 }} },
        .{ .label = "e-mixed-align", .src = e_src, .points = &.{ .{ .env = &env3, .window = cyc0 }, .{ .env = &env0, .window = cyc0 } } },
        .{ .label = "f-multi-leaf-order", .src = "(cat (pure (/ 1 base)) \"mid\" (pure (/ 2 base)))", .points = &.{ .{ .env = &env3, .window = cyc0 }, .{ .env = &env0, .window = cyc0 } } },
        .{ .label = "g1-div-base", .src = "(cat (pure (/ 1 base)) \"x\")", .points = &.{
            .{ .env = &env3, .window = cyc0 }, .{ .env = &env2, .window = cyc0 },    .{ .env = &env0, .window = cyc0 },
            .{ .env = &env2, .window = cyc0 }, .{ .env = &envmiss, .window = cyc0 }, .{ .env = &envextra, .window = cyc0 },
            .{ .env = null, .window = cyc0 },
        } },
        .{ .label = "g2-if-vector", .src = "(cat (pure (if (> base 0) 1 [1 2])) \"x\")", .points = &.{ .{ .env = &env3, .window = cyc0 }, .{ .env = &env1, .window = cyc0 }, .{ .env = &env0, .window = cyc0 }, .{ .env = &env1, .window = cyc0 } } },
        .{ .label = "h-over-budget", .src = "(fast 16 (cat \"a\" \"b\"))", .points = &.{.{ .env = &env3, .window = cyc0 }} },
        .{ .label = "i1-cat-4cycle", .src = "(cat \"alpha\" :kw sym (pure (* base 2)))", .points = &.{
            .{ .env = &env3, .window = cyc0 },                        .{ .env = &env3, .window = cyc4 },
            .{ .env = &env3, .window = Span.init(0 * PPC, 1 * PPC) }, .{ .env = &env3, .window = Span.init(1 * PPC, 2 * PPC) },
            .{ .env = &env3, .window = Span.init(2 * PPC, 3 * PPC) }, .{ .env = &env3, .window = Span.init(3 * PPC, 4 * PPC) },
        } },
        .{ .label = "i2-cat-literal-twin", .src = "(cat \"alpha\" :kw sym \"tail\")", .points = &.{
            .{ .env = &env3, .window = cyc0 },                        .{ .env = &env3, .window = cyc4 },
            .{ .env = &env3, .window = Span.init(0 * PPC, 1 * PPC) }, .{ .env = &env3, .window = Span.init(1 * PPC, 2 * PPC) },
            .{ .env = &env3, .window = Span.init(2 * PPC, 3 * PPC) }, .{ .env = &env3, .window = Span.init(3 * PPC, 4 * PPC) },
        } },
        // Review-Focus rows (1, 2, 4): full-profile payload; nonzero seed; null schema.
        // full-profile: fixture (a) encoded with forMode(.full) — spans carried;
        // span content stays excluded from comparison (expectSameOutcome).
        // seeded: fixtures (d)/(g1) at seed 7. null-schema: fixture (d) under
        // Schema.Schema.init(&.{}) — expr leaves degrade to silence on BOTH arms.
    };
    var executed: usize = 0;
    for (cases) |c| {
        var tree = try Parser.parse(gpa, c.src);
        defer tree.deinit();
        try testing.expect(!tree.hasErrors());
        var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
        defer bytes.deinit();
        const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
        var p = try PreparedBinary.fromTree(decoded);
        defer p.deinit();
        for (c.points) |pt| try checkPointCounted(gpa, &tree, &p, bytes.data, pt.window, pt.seed, pt.env, &executed);
    }
    // full-profile row: (a) at env3/cyc0, encoded with every span/comment site on
    {
        var tree = try Parser.parse(gpa, a_src);
        defer tree.deinit();
        try testing.expect(!tree.hasErrors());
        var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.full));
        defer bytes.deinit();
        const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
        var p = try PreparedBinary.fromTree(decoded);
        defer p.deinit();
        try checkPointCounted(gpa, &tree, &p, bytes.data, cyc0, 0, &env3, &executed);
    }
    // seeded rows: (d) and (g1) at seed 7 (nonzero — the battery body runs seed 0)
    {
        var tree = try Parser.parse(gpa, d_src);
        defer tree.deinit();
        try testing.expect(!tree.hasErrors());
        var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
        defer bytes.deinit();
        const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
        var p = try PreparedBinary.fromTree(decoded);
        defer p.deinit();
        try checkPointCounted(gpa, &tree, &p, bytes.data, cyc0, 7, &env3, &executed);
    }
    {
        const g1_src: [:0]const u8 = "(cat (pure (/ 1 base)) \"x\")";
        var tree = try Parser.parse(gpa, g1_src);
        defer tree.deinit();
        try testing.expect(!tree.hasErrors());
        var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
        defer bytes.deinit();
        const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
        var p = try PreparedBinary.fromTree(decoded);
        defer p.deinit();
        try checkPointCounted(gpa, &tree, &p, bytes.data, cyc0, 7, &env3, &executed);
    }
    // null-schema row: (d) — expr leaves degrade to silence on both arms
    {
        var tree = try Parser.parse(gpa, d_src);
        defer tree.deinit();
        try testing.expect(!tree.hasErrors());
        var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
        defer bytes.deinit();
        const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
        var p = try PreparedBinary.fromTree(decoded);
        defer p.deinit();
        const empty = Schema.Schema.init(&.{});
        var rt = try queryTreeWithEnv(gpa, &tree, tree.root[0], empty, cyc0, 0, &env3);
        defer rt.deinit();
        var rp = try queryPreparedBinaryWithEnv(gpa, &p, empty, cyc0, 0, &env3);
        defer rp.deinit();
        try expectSameOutcome(&rt, &rp);
        executed += 1;
    }
    // Coverage assertion — computed from the declared table, never copied from
    // a report: 32 carried points (plan D3 Step 1: a=1 b=1 c=1 d=1 e=2 f=2
    // g1=7 g2=4 h=1 i1=6 i2=6) + 4 extension rows (full-profile ×1, nonzero
    // seed ×2, null-schema ×1).
    var declared: usize = 0;
    for (cases) |c| declared += c.points.len;
    declared += 4;
    try testing.expectEqual(declared, executed);
    try testing.expect(executed >= 32); // the carried set alone (plan.md:849)
}

// ---- T-FLOORS (plan D3 Step 2) ---------------------------------------------
//
// 4-KiB-granular FixedBufferAllocator floors under `page_allocator` buffers:
// the production budget's own granularity. Floors are GRANULAR, never exact
// minima — the values recorded/pinned here are actual measurements at 4-KiB
// resolution. `attemptQuery` runs one arm's query under a caller-supplied
// allocator and returns success or `error.OutOfMemory` — any other error is a
// test failure.

const floors_granule: usize = 4096;
const floors_cap: usize = 8 << 20; // 8 MiB bisection ceiling
const floors_mib: usize = 1 << 20; // the SCRATCH_BYTES-class 1-MiB outcome point

const FloorsArm = enum { text, oneshot, prepared };

const FloorsFixture = struct {
    label: []const u8,
    tree: Ast.Tree,
    bytes: Ast.Bytes,
    prepared: PreparedBinary,
};

fn floorsBuildFixture(gpa: Allocator, label: []const u8, src: [:0]const u8) !FloorsFixture {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    var tree = try Parser.parse(gpa, src);
    errdefer tree.deinit();
    try testing.expect(!tree.hasErrors());
    var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
    errdefer bytes.deinit();
    const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
    // fromTree consumes `decoded` (frees it internally on the error path).
    const prepared = try PreparedBinary.fromTree(decoded);
    return .{ .label = label, .tree = tree, .bytes = bytes, .prepared = prepared };
}

fn floorsFreeFixture(f: *FloorsFixture) void {
    f.prepared.deinit();
    f.bytes.deinit();
    f.tree.deinit();
}

fn floorsAttempt(a: Allocator, arm: FloorsArm, f: *const FloorsFixture) !bool {
    const window = Span.init(0, PPC);
    const env = testEnvBase3();
    switch (arm) {
        .text => {
            var r = queryTreeWithEnv(a, &f.tree, f.tree.root[0], patternSchema(), window, 0, &env) catch |e| switch (e) {
                error.OutOfMemory => return false,
                else => return e, // any other error is a test failure
            };
            defer r.deinit();
            return true;
        },
        .oneshot => {
            var r = queryBinaryWithBudgetAndEnv(a, f.bytes.data, patternSchema(), window, 0, .{}, &env) catch |e| switch (e) {
                error.OutOfMemory => return false,
                else => return e,
            };
            defer r.deinit();
            return true;
        },
        .prepared => {
            var r = queryPreparedBinaryWithEnv(a, &f.prepared, patternSchema(), window, 0, &env) catch |e| switch (e) {
                error.OutOfMemory => return false,
                else => return e,
            };
            defer r.deinit();
            return true;
        },
    }
}

fn floorsAttemptSized(page_buf: []u8, n: usize, arm: FloorsArm, f: *const FloorsFixture) !bool {
    var fba = std.heap.FixedBufferAllocator.init(page_buf[0..n]);
    return floorsAttempt(fba.allocator(), arm, f);
}

/// Smallest 4-KiB-granular buffer size (≤ floors_cap) at which `arm` succeeds.
/// Bisection over the granule axis (permitted once success is seen); the
/// reported floor stays 4-KiB-granular. Invariant: `lo` fails (0 fails by
/// definition — a query cannot succeed with no buffer), `hi` succeeds.
fn floorsFloorOf(arm: FloorsArm, f: *const FloorsFixture) !usize {
    const buf = try std.heap.page_allocator.alloc(u8, floors_cap);
    defer std.heap.page_allocator.free(buf);
    if (!try floorsAttemptSized(buf, floors_cap, arm, f)) return error.FloorAboveCap;
    var lo: usize = 0;
    var hi: usize = floors_cap;
    while (hi - lo > floors_granule) {
        const mid = (lo + hi) / 2 / floors_granule * floors_granule;
        if (try floorsAttemptSized(buf, mid, arm, f)) hi = mid else lo = mid;
    }
    return hi;
}

fn floorsAnchor(fixture_label: []const u8, arm_label: []const u8, measured: usize, expected: usize) !void {
    if (measured != expected) {
        std.debug.print("anchor {s}/{s}: measured={d} expected={d} — a std/toolchain change moved the floor; investigate before re-pinning\n", .{ fixture_label, arm_label, measured, expected });
        return error.AnchorMoved;
    }
}

test "prepared: acceptance floors == text floors at 4-KiB granularity (9 anchors pinned; native trip-wire)" {
    const gpa = testing.allocator;
    const a_src = try buildBallastSource(gpa, true);
    defer gpa.free(a_src);
    const b_src = try buildBallastSource(gpa, false);
    defer gpa.free(b_src);
    const c_src = try buildPoolRichSource(gpa, pool_rich_count);
    defer gpa.free(c_src);
    const d_src = try buildDenseExprSource(gpa);
    defer gpa.free(d_src);
    const e_src = try buildMixedAlignmentSource(gpa);
    defer gpa.free(e_src);
    const Src = struct { label: []const u8, src: [:0]const u8 };
    const srcs = [_]Src{
        .{ .label = "a-repro-a-exact", .src = a_src },
        .{ .label = "b-literal-twin", .src = b_src },
        .{ .label = "c-pool-rich-2048", .src = c_src },
        .{ .label = "d-dense-expr", .src = d_src },
        .{ .label = "e-mixed-align", .src = e_src },
        .{ .label = "f-multi-leaf-order", .src = "(cat (pure (/ 1 base)) \"mid\" (pure (/ 2 base)))" },
        .{ .label = "g1-div-base", .src = "(cat (pure (/ 1 base)) \"x\")" },
        .{ .label = "g2-if-vector", .src = "(cat (pure (if (> base 0) 1 [1 2])) \"x\")" },
        .{ .label = "h-over-budget", .src = "(fast 16 (cat \"a\" \"b\"))" },
        .{ .label = "i1-cat-4cycle", .src = "(cat \"alpha\" :kw sym (pure (* base 2)))" },
        .{ .label = "i2-cat-literal-twin", .src = "(cat \"alpha\" :kw sym \"tail\")" },
    };

    var fixtures: [srcs.len]FloorsFixture = undefined;
    var built: usize = 0;
    errdefer {
        for (fixtures[0..built]) |*f| floorsFreeFixture(f);
    }
    for (srcs, 0..) |s, i| {
        fixtures[i] = try floorsBuildFixture(gpa, s.label, s.src);
        built = i + 1;
    }
    defer {
        for (&fixtures) |*f| floorsFreeFixture(f);
    }

    // Original Repro A fingerprint: the compact payload the anchors below were
    // measured against (spike30-full.log:2 — compact=98501B).
    try testing.expectEqual(@as(usize, 98501), fixtures[0].bytes.data.len);

    var floor_text: [srcs.len]usize = undefined;
    var floor_oneshot: [srcs.len]usize = undefined;
    var floor_prepared: [srcs.len]usize = undefined;
    for (&fixtures, 0..) |*f, i| {
        floor_text[i] = try floorsFloorOf(.text, f);
        floor_oneshot[i] = try floorsFloorOf(.oneshot, f);
        floor_prepared[i] = try floorsFloorOf(.prepared, f);
        // The portable relation, per fixture (plan D3 Step 2). The one-shot is
        // recorded only — its divergence is the documented pre-existing gap
        // (A.7), never asserted away.
        try testing.expectEqual(floor_text[i], floor_prepared[i]);
        std.debug.print("floors [{s}]: text={d} oneshot={d} prepared={d} (4-KiB granular, actual — not exact minima)\n", .{ f.label, floor_text[i], floor_oneshot[i], floor_prepared[i] });
    }

    // Absolute anchors (native, pinned-toolchain trip-wires — 9): a toolchain/
    // std shift that moves a floor trips this test BY DESIGN.
    try floorsAnchor("a-repro-a-exact", "text", floor_text[0], 753664);
    try floorsAnchor("a-repro-a-exact", "prepared", floor_prepared[0], 753664);
    try floorsAnchor("a-repro-a-exact", "oneshot", floor_oneshot[0], 1253376);
    try floorsAnchor("b-literal-twin", "text", floor_text[1], 753664);
    try floorsAnchor("b-literal-twin", "prepared", floor_prepared[1], 753664);
    try floorsAnchor("b-literal-twin", "oneshot", floor_oneshot[1], 761856);
    try floorsAnchor("c-pool-rich-2048", "text", floor_text[2], 806912);
    try floorsAnchor("c-pool-rich-2048", "prepared", floor_prepared[2], 806912);
    try floorsAnchor("c-pool-rich-2048", "oneshot", floor_oneshot[2], 659456);

    // 1-MiB outcome pins: Repro A text/prepared accept, one-shot REFUSES
    // (window closure — its floor is 1,253,376 > 1 MiB); b and c accept on
    // every arm.
    const mib_buf = try std.heap.page_allocator.alloc(u8, floors_mib);
    defer std.heap.page_allocator.free(mib_buf);
    try testing.expect(try floorsAttemptSized(mib_buf, floors_mib, .text, &fixtures[0]));
    try testing.expect(try floorsAttemptSized(mib_buf, floors_mib, .prepared, &fixtures[0]));
    try testing.expect(!try floorsAttemptSized(mib_buf, floors_mib, .oneshot, &fixtures[0]));
    try testing.expect(try floorsAttemptSized(mib_buf, floors_mib, .text, &fixtures[1]));
    try testing.expect(try floorsAttemptSized(mib_buf, floors_mib, .oneshot, &fixtures[1]));
    try testing.expect(try floorsAttemptSized(mib_buf, floors_mib, .prepared, &fixtures[1]));
    try testing.expect(try floorsAttemptSized(mib_buf, floors_mib, .text, &fixtures[2]));
    try testing.expect(try floorsAttemptSized(mib_buf, floors_mib, .oneshot, &fixtures[2]));
    try testing.expect(try floorsAttemptSized(mib_buf, floors_mib, .prepared, &fixtures[2]));
}

// ---- T-FRESHNESS / T-COMBINED / T-ORDER / T-BITEXACT / T-LIMITS (D3) -------

test "prepared: env freshness on ONE prepared object — exact values pinned, text oracle at each step" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    const env3 = testEnvBase3();
    const bind2 = [_]Expr.Env.Binding{.{ .name = "base", .value = .{ .number = 2.0 } }};
    const env2: Expr.Env = .{ .bindings = &bind2 };
    const bind1 = [_]Expr.Env.Binding{.{ .name = "base", .value = .{ .number = 1.0 } }};
    const env1: Expr.Env = .{ .bindings = &bind1 };
    const bind0 = [_]Expr.Env.Binding{.{ .name = "base", .value = .{ .number = 0.0 } }};
    const env0: Expr.Env = .{ .bindings = &bind0 };
    const bindmiss = [_]Expr.Env.Binding{.{ .name = "sway", .value = .{ .number = 0.25 } }};
    const envmiss: Expr.Env = .{ .bindings = &bindmiss };
    const bindextra = [_]Expr.Env.Binding{
        .{ .name = "base", .value = .{ .number = 3.0 } },
        .{ .name = "unrelated", .value = .{ .number = 7.0 } },
    };
    const envextra: Expr.Env = .{ .bindings = &bindextra };
    const cyc0 = Span.init(0, PPC);

    const Expect = struct {
        haps: usize,
        bits: u64 = 0, // raw f64 bits of the single `.number` hap (g1 only)
        want_value: ?PatValue = null, // variant-aware expectation (review I1): compared with `eql` (tag-first) — g2's value is `.integer_i64`
        diags: usize,
        code: ?Ast.Diagnostic.Code = null,
    };
    const Step = struct { env: ?*const Expr.Env, want: Expect };

    // g1: (cat (pure (/ 1 base)) "x") — cycle 0 evaluates the leaf only.
    var tree1 = try Parser.parse(gpa, "(cat (pure (/ 1 base)) \"x\")");
    defer tree1.deinit();
    try testing.expect(!tree1.hasErrors());
    var bytes1 = try Binary.toBinary(gpa, tree1, Binary.ToBinaryOptions.forMode(.compact));
    defer bytes1.deinit();
    const dec1 = try Binary.fromBinary(gpa, bytes1.data, .{});
    var p1 = try PreparedBinary.fromTree(dec1);
    defer p1.deinit();
    const g1_steps = [_]Step{
        .{ .env = &env3, .want = .{ .haps = 1, .bits = 0x3FD5555555555555, .diags = 0 } }, // 1/3
        .{ .env = &env2, .want = .{ .haps = 1, .bits = 0x3FE0000000000000, .diags = 0 } }, // 0.5
        .{ .env = &env0, .want = .{ .haps = 0, .diags = 1, .code = .pattern_value_eval_failed } }, // DivisionByZero
        .{ .env = &env2, .want = .{ .haps = 1, .bits = 0x3FE0000000000000, .diags = 0 } }, // recovery
        .{ .env = &envmiss, .want = .{ .haps = 0, .diags = 1, .code = .pattern_value_eval_failed } }, // unbound base
        .{ .env = &envextra, .want = .{ .haps = 1, .bits = 0x3FD5555555555555, .diags = 0 } }, // extra binding inert
        .{ .env = null, .want = .{ .haps = 0, .diags = 1, .code = .pattern_value_eval_failed } }, // null env
    };
    for (g1_steps) |s| {
        var rp = try queryPreparedBinaryWithEnv(gpa, &p1, patternSchema(), cyc0, 0, s.env);
        defer rp.deinit();
        var rt = try queryTreeWithEnv(gpa, &tree1, tree1.root[0], patternSchema(), cyc0, 0, s.env);
        defer rt.deinit();
        try expectSameOutcome(&rt, &rp); // prepared ≡ text under the identical env
        try testing.expectEqual(s.want.haps, rp.haps.len); // literal expectations, arm-independent
        try testing.expectEqual(s.want.diags, rp.diagnostics.len);
        if (s.want.haps == 1) try testing.expectEqual(s.want.bits, @as(u64, @bitCast(rp.haps[0].value.number)));
        if (s.want.code) |code| {
            try testing.expectEqual(code, rp.diagnostics[0].code);
            try testing.expectEqual(@as(usize, 1), rp.diagnostics[0].path.len);
            try testing.expectEqualStrings("pure", rp.diagnostics[0].path[0]);
        }
    }

    // g2: (cat (pure (if (> base 0) 1 [1 2])) "x") — result-SHAPE drift.
    var tree2 = try Parser.parse(gpa, "(cat (pure (if (> base 0) 1 [1 2])) \"x\")");
    defer tree2.deinit();
    try testing.expect(!tree2.hasErrors());
    var bytes2 = try Binary.toBinary(gpa, tree2, Binary.ToBinaryOptions.forMode(.compact));
    defer bytes2.deinit();
    const dec2 = try Binary.fromBinary(gpa, bytes2.data, .{});
    var p2 = try PreparedBinary.fromTree(dec2);
    defer p2.deinit();
    const g2_steps = [_]Step{
        // `(if (> base 0) 1 [1 2])` returns the branch literal verbatim
        // (Expr.zig scheduleIf); an integer literal is captured as
        // `.integer_i64` (Expr.zig fromExprValue → PatternQuery.fromExprValue)
        // — reading `.number` on that variant would panic in test builds.
        // Pin the variant (review I1), not float bits.
        .{ .env = &env1, .want = .{ .haps = 1, .want_value = .{ .integer_i64 = 1 }, .diags = 0 } }, // 1
        .{ .env = &env0, .want = .{ .haps = 0, .diags = 1, .code = .pattern_value_result_invalid } }, // vector result
        .{ .env = &env1, .want = .{ .haps = 1, .want_value = .{ .integer_i64 = 1 }, .diags = 0 } }, // recovery
    };
    for (g2_steps) |s| {
        var rp = try queryPreparedBinaryWithEnv(gpa, &p2, patternSchema(), cyc0, 0, s.env);
        defer rp.deinit();
        var rt = try queryTreeWithEnv(gpa, &tree2, tree2.root[0], patternSchema(), cyc0, 0, s.env);
        defer rt.deinit();
        try expectSameOutcome(&rt, &rp);
        try testing.expectEqual(s.want.haps, rp.haps.len);
        try testing.expectEqual(s.want.diags, rp.diagnostics.len);
        if (s.want.want_value) |wv| try testing.expect(wv.eql(rp.haps[0].value)); // variant-aware (review I1)
        if (s.want.code) |code| try testing.expectEqual(code, rp.diagnostics[0].code);
    }
}

test "prepared: combined budget+env exercised simultaneously (exact errors pinned, both axes active, positive control)" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    // Both axes must observably affect this fixture (review carry on the
    // plan's env-inert h fixture): under env3 the pure leaf yields 6.0 →
    // 32 haps over the cycle; under a null env the leaf degrades to silence
    // at the compile dry-run → 16 haps + 1 diagnostic. So lowering the budget
    // axis OR changing the env is observable on the SAME prepared object,
    // and the plan's exact refusal pins (haps=8 / bytes=2048, spike-verified
    // on this fixture class) hold: the fixture here is a strict superset of
    // the plan's `(fast 16 (cat "a" "b"))` payload.
    var tree = try Parser.parse(gpa, "(fast 16 (cat \"a\" (pure (* base 2))))");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bytes.deinit();
    const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
    var p = try PreparedBinary.fromTree(decoded);
    defer p.deinit();
    const env = testEnvBase3();
    const schema = patternSchema();
    const window = Span.init(0, PPC);

    // hap-budget refusal, exact error, on the combined entry AND the tree oracle
    try testing.expectError(error.HapBudgetExceeded, queryPreparedBinaryWithBudgetAndEnv(gpa, &p, schema, window, 0, .{ .haps = 8 }, &env));
    try testing.expectError(error.HapBudgetExceeded, queryTreeFull(gpa, &tree, tree.root[0], schema, window, 0, .{ .haps = 8 }, &env));
    // byte-budget refusal, exact error, both arms
    try testing.expectError(error.MemoryBudgetExceeded, queryPreparedBinaryWithBudgetAndEnv(gpa, &p, schema, window, 0, .{ .bytes = 2048 }, &env));
    try testing.expectError(error.MemoryBudgetExceeded, queryTreeFull(gpa, &tree, tree.root[0], schema, window, 0, .{ .bytes = 2048 }, &env));

    // positive control: sufficient budget + live env → success, pinned shape
    var ok_p = try queryPreparedBinaryWithBudgetAndEnv(gpa, &p, schema, window, 0, .{}, &env);
    defer ok_p.deinit();
    var ok_t = try queryTreeFull(gpa, &tree, tree.root[0], schema, window, 0, .{}, &env);
    defer ok_t.deinit();
    try expectSameOutcome(&ok_t, &ok_p);
    try testing.expect(ok_p.haps.len > 0); // positive control really controls
    // measured on the unchanged text oracle (d3-probe-out.log): fast 16
    // repeats the cat within the cycle; the cat's two children alternate per
    // repeat → 16 haps, even slots "a", odd slots 6.0.
    try testing.expectEqual(@as(usize, 16), ok_p.haps.len);
    try testing.expectEqualStrings("a", ok_p.haps[0].value.string);
    try testing.expectEqual(@as(u64, 0x4018000000000000), @as(u64, @bitCast(ok_p.haps[1].value.number))); // base=3 reached the prepared leaf: 3×2

    // env axis is live on the SAME entry: null env degrades the leaf
    var ok_null = try queryPreparedBinaryWithBudgetAndEnv(gpa, &p, schema, window, 0, .{}, null);
    defer ok_null.deinit();
    var ok_null_t = try queryTreeFull(gpa, &tree, tree.root[0], schema, window, 0, .{}, null);
    defer ok_null_t.deinit();
    try expectSameOutcome(&ok_null_t, &ok_null);
    try testing.expectEqual(@as(usize, 8), ok_null.haps.len); // string hap only, 8 of the 16 repeats
    try testing.expectEqual(@as(usize, 1), ok_null.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.pattern_value_eval_failed, ok_null.diagnostics[0].code);
    // both axes affect the fixture — the env change moved the outcome:
    try testing.expect(ok_p.haps.len != ok_null.haps.len);
    try testing.expect(ok_p.diagnostics.len != ok_null.diagnostics.len);
}

test "prepared: multi-leaf dry-run diagnostic order ≡ text (discriminating codes; one-shot gap recorded, not asserted)" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    // base=0: two failing expr leaves with DISTINCT codes so traversal order
    // is observable in the output — leaf 1 `(/ 1 base)` hits DivisionByZero
    // (pattern_value_eval_failed); leaf 2 `(vec2 1 2)` yields a vector, which
    // a hap cannot carry (pattern_value_result_invalid). The spike's (f)
    // fixture was order-BLIND (both leaves emitted eval_failed — see
    // spike30-full-rerun.log:22); this fixture is the parent-4 correction.
    // The ORACLE is the original text arm (the parsed tree), never a decoded
    // copy mapped to the same shape.
    const src: [:0]const u8 = "(cat (pure (/ 1 base)) (pure (vec2 1 2)))";
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bytes.deinit();
    const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
    var p = try PreparedBinary.fromTree(decoded);
    defer p.deinit();
    const bind0 = [_]Expr.Env.Binding{.{ .name = "base", .value = .{ .number = 0.0 } }};
    const env0: Expr.Env = .{ .bindings = &bind0 };
    const window = Span.init(0, PPC);

    // text oracle FIRST — the authority for what the ordered pair must be.
    // The compile dry-run is REVERSE-POSITIONAL (the documented pre-existing
    // tree-path mechanism, plan §B/§77): the vec2 leaf is diagnosed first.
    // The fixture is preserved verbatim; the pins below are the oracle's own
    // measured output (d3-probe-out.log), not an assumption of source order.
    var rt = try queryTreeWithEnv(gpa, &tree, tree.root[0], patternSchema(), window, 0, &env0);
    defer rt.deinit();
    // ordered pair pinned as literals, in the oracle's dry-run order:
    try testing.expectEqual(@as(usize, 2), rt.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.pattern_value_result_invalid, rt.diagnostics[0].code);
    try testing.expectEqual(Ast.Diagnostic.Code.pattern_value_eval_failed, rt.diagnostics[1].code);
    try testing.expectEqual(@as(usize, 1), rt.diagnostics[0].path.len);
    try testing.expectEqualStrings("pure", rt.diagnostics[0].path[0]);
    try testing.expectEqual(@as(usize, 1), rt.diagnostics[1].path.len);
    try testing.expectEqualStrings("pure", rt.diagnostics[1].path[0]);
    try testing.expectEqual(@as(usize, 0), rt.haps.len);

    // prepared inherits the tree's order BY SHARING compileTree — pinned
    // order-sensitively (codes differ, so any swap fails these pins):
    var rp = try queryPreparedBinaryWithEnv(gpa, &p, patternSchema(), window, 0, &env0);
    defer rp.deinit();
    try expectSameOutcome(&rt, &rp); // compares diagnostics per-index IN ORDER
    try testing.expectEqual(Ast.Diagnostic.Code.pattern_value_result_invalid, rp.diagnostics[0].code);
    try testing.expectEqual(Ast.Diagnostic.Code.pattern_value_eval_failed, rp.diagnostics[1].code);

    // secondary control under base=3: only the vec2 leaf fails → 1 hap (1/3)
    // + 1 diagnostic — the discriminating pair above is base-0-specific.
    const bind3 = [_]Expr.Env.Binding{.{ .name = "base", .value = .{ .number = 3.0 } }};
    const env3: Expr.Env = .{ .bindings = &bind3 };
    var rt3 = try queryTreeWithEnv(gpa, &tree, tree.root[0], patternSchema(), window, 0, &env3);
    defer rt3.deinit();
    var rp3 = try queryPreparedBinaryWithEnv(gpa, &p, patternSchema(), window, 0, &env3);
    defer rp3.deinit();
    try expectSameOutcome(&rt3, &rp3);
    try testing.expectEqual(@as(usize, 1), rp3.haps.len);
    try testing.expectEqual(@as(u64, 0x3FD5555555555555), @as(u64, @bitCast(rp3.haps[0].value.number)));
    try testing.expectEqual(@as(usize, 1), rp3.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.pattern_value_result_invalid, rp3.diagnostics[0].code);

    // one-shot: its order is the documented pre-existing gap (A.7) — recorded,
    // never asserted:
    if (queryBinaryWithBudgetAndEnv(gpa, bytes.data, patternSchema(), window, 0, .{}, &env0)) |res| {
        var ro = res;
        defer ro.deinit();
        std.debug.print("  [recorded] one-shot order: ", .{});
        for (ro.diagnostics) |d| std.debug.print("{s}@{s} ", .{ @tagName(d.code), d.path[0] });
        std.debug.print("haps={d}\n", .{ro.haps.len});
    } else |e| {
        std.debug.print("  [recorded] one-shot error: {s}\n", .{@errorName(e)});
    }
}

test "prepared: bit-exact value fidelity — signed zero, large i64, u64 (literal pins)" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    // NaN is NOT reachable through the pattern grammar's closed vocabulary:
    // there is no NaN literal, and the expr vocabulary's domain errors surface
    // as drops/diagnostics, never NaN haps. Stated, not faked with a
    // constructed case (plan D3 Step 6).
    var tree = try Parser.parse(gpa, "(cat (pure -0.0) (pure 9007199254740993) (pure 18446744073709551615))");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bytes.deinit();
    const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
    var p = try PreparedBinary.fromTree(decoded);
    defer p.deinit();
    const window = Span.init(0, 3 * PPC); // cat alternates its children per cycle — 3 children need 3 cycles
    var rp = try queryPreparedBinaryWithEnv(gpa, &p, patternSchema(), window, 0, null);
    defer rp.deinit();
    var rt = try queryTreeWithEnv(gpa, &tree, tree.root[0], patternSchema(), window, 0, null);
    defer rt.deinit();
    try expectSameOutcome(&rt, &rp); // prepared ≡ text (PatValue.eql: raw bits)

    // literal expectations, arm-independent (measured on the unchanged text
    // oracle, d3-probe2-out.log: one hap per cycle, children in source order);
    // tags first (no widen/narrow):
    try testing.expectEqual(@as(usize, 3), rp.haps.len);
    try testing.expectEqualStrings("number", @tagName(rp.haps[0].value));
    // -0.0: raw bits 0x8000000000000000 — distinct from +0.0; `eql` compares
    // raw f64 bits, so any ±0.0 smoothing fails the pins below.
    try testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(rp.haps[0].value.number)));
    try testing.expect(rp.haps[0].value.eql(.{ .number = -0.0 }));
    try testing.expect(!rp.haps[0].value.eql(.{ .number = 0.0 })); // same tag, different bits
    try testing.expectEqualStrings("integer_i64", @tagName(rp.haps[1].value));
    try testing.expectEqual(@as(i64, 9007199254740993), rp.haps[1].value.integer_i64);
    try testing.expect(rp.haps[1].value.eql(.{ .integer_i64 = 9007199254740993 }));
    try testing.expect(!rp.haps[1].value.eql(.{ .number = 9007199254740993.0 })); // tag mismatch fails
    try testing.expectEqualStrings("integer_u64", @tagName(rp.haps[2].value));
    try testing.expectEqual(@as(u64, 18446744073709551615), rp.haps[2].value.integer_u64);
    try testing.expect(rp.haps[2].value.eql(.{ .integer_u64 = 18446744073709551615 }));
}

/// Flat n-child `cat` source for the T-LIMITS shape ceiling (source-owned;
/// the pool-rich builder chunks by 512 — this one deliberately does not).
fn buildFlatCatSource(gpa: Allocator, n: usize) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "(cat (pure 0.5)");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var idx: [16]u8 = undefined;
        const digits = try std.fmt.bufPrint(&idx, " \"q{d:0>4}\"", .{i});
        try buf.appendSlice(gpa, digits);
    }
    try buf.appendSlice(gpa, ")");
    try buf.append(gpa, 0);
    const all = try buf.toOwnedSlice(gpa);
    return all[0 .. all.len - 1 :0];
}

test "prepared: engine ceilings bite identically — 2049-child flat cat refuses DepthExceeded on prepared AND text (positive control)" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    const schema = patternSchema();
    const window = Span.init(0, PPC);
    // (i) MAX_COMPILE_FRAMES = 1024: the intake's 2049-child flat `cat` —
    // the tree path refuses, and the prepared path refuses identically
    // (prepare itself succeeds: the payload is flat, so neither the parser's
    // depth ceiling nor the decoder's node cap is touched — it is the
    // compile frame ceiling that bites, on both paths, in the same code).
    const flat_src = try buildFlatCatSource(gpa, 2049);
    defer gpa.free(flat_src);
    {
        var tree = try Parser.parse(gpa, flat_src);
        defer tree.deinit();
        try testing.expect(!tree.hasErrors());
        var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
        defer bytes.deinit();
        const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
        var p = try PreparedBinary.fromTree(decoded); // prepare succeeds
        defer p.deinit();
        try testing.expectError(error.DepthExceeded, queryTreeWithEnv(gpa, &tree, tree.root[0], schema, window, 0, null));
        try testing.expectError(error.DepthExceeded, queryPreparedBinary(gpa, &p, schema, window, 0));
    }
    // (ii) the HapBudgetExceeded / MemoryBudgetExceeded ceiling pins are
    // T-COMBINED's (same family, same seam) and count toward this limit set.
    // Positive control: a 512-child flat cat is under the frame ceiling and
    // queries fine on BOTH paths.
    const ok_src = try buildFlatCatSource(gpa, 512);
    defer gpa.free(ok_src);
    {
        var tree = try Parser.parse(gpa, ok_src);
        defer tree.deinit();
        try testing.expect(!tree.hasErrors());
        var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
        defer bytes.deinit();
        const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
        var p = try PreparedBinary.fromTree(decoded);
        defer p.deinit();
        var rt = try queryTreeWithEnv(gpa, &tree, tree.root[0], schema, window, 0, null);
        defer rt.deinit();
        var rp = try queryPreparedBinaryWithEnv(gpa, &p, schema, window, 0, null);
        defer rp.deinit();
        try expectSameOutcome(&rt, &rp);
        try testing.expect(rt.haps.len > 0); // positive control really controls
    }
}

// ---- four-entry defaults sweep (D2 review MEDIUM-1, closed in D3) ----------

test "prepared: all four entries execute — defaults contract pinned, env forwarded, budget-only refusal, zero-root silence (review MEDIUM-1)" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    const schema = patternSchema();
    const window = Span.init(0, PPC);

    // Nonzero single-root outputs: every one of the four pub entries really
    // executes and is pinned against the text oracle and its siblings. The
    // fixture is the T-COMBINED one (its default-env run emits 8 haps — more
    // than one — so a default-budget miswiring is observable here, which the
    // 1-hap smoke fixture could not catch).
    {
        var tree = try Parser.parse(gpa, "(fast 16 (cat \"a\" (pure (* base 2))))");
        defer tree.deinit();
        try testing.expect(!tree.hasErrors());
        var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
        defer bytes.deinit();
        const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
        var p = try PreparedBinary.fromTree(decoded);
        defer p.deinit();
        const env = testEnvBase3();

        // the four pub entries, each called in full with its defaults:
        var r_plain = try queryPreparedBinary(gpa, &p, schema, window, 0);
        defer r_plain.deinit();
        var r_env_null = try queryPreparedBinaryWithEnv(gpa, &p, schema, window, 0, null);
        defer r_env_null.deinit();
        var r_budget_default = try queryPreparedBinaryWithBudget(gpa, &p, schema, window, 0, .{});
        defer r_budget_default.deinit();
        var r_both_default = try queryPreparedBinaryWithBudgetAndEnv(gpa, &p, schema, window, 0, .{}, null);
        defer r_both_default.deinit();

        // defaults contract: plain == WithEnv(null) == WithBudget(default)
        //                 == WithBudgetAndEnv(default, null)
        var rt = try queryTreeWithEnv(gpa, &tree, tree.root[0], schema, window, 0, null);
        defer rt.deinit();
        try expectSameOutcome(&rt, &r_plain);
        try expectSameOutcome(&r_plain, &r_env_null);
        try expectSameOutcome(&r_plain, &r_budget_default);
        try expectSameOutcome(&r_plain, &r_both_default);

        // nonzero outputs — no entry is vacuously silent: 8 string haps plus
        // the compile-time diagnostic of the unbound pure leaf (measured on
        // the unchanged text oracle, d3-probe-out.log).
        try testing.expectEqual(@as(usize, 8), r_plain.haps.len);
        try testing.expectEqual(@as(usize, 0), r_plain.dropped);
        try testing.expectEqual(@as(usize, 1), r_plain.diagnostics.len);
        try testing.expectEqual(Ast.Diagnostic.Code.pattern_value_eval_failed, r_plain.diagnostics[0].code);
        for (r_plain.haps) |h| try testing.expectEqualStrings("a", h.value.string);

        // env is forwarded, NOT ignored: WithEnv(&env) observably differs from
        // the null-env default (16 haps, no diagnostic, 6.0 from base=3).
        var r_env3 = try queryPreparedBinaryWithEnv(gpa, &p, schema, window, 0, &env);
        defer r_env3.deinit();
        var rt3 = try queryTreeWithEnv(gpa, &tree, tree.root[0], schema, window, 0, &env);
        defer rt3.deinit();
        try expectSameOutcome(&rt3, &r_env3);
        try testing.expectEqual(@as(usize, 16), r_env3.haps.len);
        try testing.expectEqual(@as(usize, 0), r_env3.diagnostics.len);
        try testing.expectEqual(@as(u64, 0x4018000000000000), @as(u64, @bitCast(r_env3.haps[1].value.number)));
        try testing.expect(r_env3.haps.len != r_plain.haps.len); // env axis moved the outcome

        // budget-only entry with a lowered budget actually refuses (exact
        // expected error; the null-env run emits 8 haps, so 8 > 7 refuses)…
        try testing.expectError(error.HapBudgetExceeded, queryPreparedBinaryWithBudget(gpa, &p, schema, window, 0, .{ .haps = 7 }));
        // …with the accepting positive control on the SAME entry: the
        // boundary budget (8 emitted, cap 8 — enforcement is `>`) is accepted.
        var r_ok_budget = try queryPreparedBinaryWithBudget(gpa, &p, schema, window, 0, .{ .haps = 8 });
        defer r_ok_budget.deinit();
        try testing.expectEqual(@as(usize, 8), r_ok_budget.haps.len);
    }
    // Zero-root silence: every entry answers the silence shape.
    {
        var tree = try Parser.parse(gpa, "");
        defer tree.deinit();
        var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
        defer bytes.deinit();
        const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
        var p = try PreparedBinary.fromTree(decoded);
        defer p.deinit();
        const env = testEnvBase3();
        var r0 = try queryPreparedBinary(gpa, &p, schema, window, 0);
        defer r0.deinit();
        var r1 = try queryPreparedBinaryWithEnv(gpa, &p, schema, window, 0, null);
        defer r1.deinit();
        var r2 = try queryPreparedBinaryWithBudget(gpa, &p, schema, window, 0, .{});
        defer r2.deinit();
        var r3 = try queryPreparedBinaryWithBudgetAndEnv(gpa, &p, schema, window, 0, .{}, &env);
        defer r3.deinit();
        for ([4]*const Result{ &r0, &r1, &r2, &r3 }) |r| {
            try testing.expectEqual(@as(usize, 0), r.haps.len);
            try testing.expectEqual(@as(usize, 0), r.dropped);
            try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
        }
    }
}

// ---- T-LIFETIME: the Result is self-contained under poisoned inputs (D4) ----
//
// The real contract (parent 1): an actual owning `Result` stays valid after
// the input bytes, the prepared tree, AND the original parsed tree are all
// poisoned and freed. No fingerprint / deep-copy stand-in — the assertions
// read the ORIGINAL `Result` fields. The poison allocator is distinct from
// the result allocator (`testing.allocator`), and every `free` forwarded to
// the io child is poison-scribbled first, so any aliasing reader observes
// garbage instead of stale-but-valid bytes.
//
// Fixture grammar note (plan D4 Step 1): `(cat …)` yields string+number haps
// from bare atoms; keyword/symbol slices come from `(pure …)` positionals —
// the supported slice set of `compileValue`. Booleans / nil / integers are
// slice-free and are pinned value-exactly in T-BITEXACT (D3), not here.

const PoisonAllocator = struct {
    child: std.mem.Allocator,
    poisoned_frees: usize = 0,

    fn allocator(self: *PoisonAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        } };
    }
    fn allocFn(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ptr));
        return self.child.rawAlloc(len, alignment, ra);
    }
    fn resizeFn(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ptr));
        return self.child.rawResize(memory, alignment, new_len, ra);
    }
    fn remapFn(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ptr));
        return self.child.rawRemap(memory, alignment, new_len, ra);
    }
    fn freeFn(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ptr));
        @memset(memory, 0xAA); // poison BEFORE forwarding the free — an aliasing reader sees garbage
        self.poisoned_frees += 1;
        self.child.rawFree(memory, alignment, ra);
    }
};

test "prepared: Result slices are self-contained — valid after bytes+prepared+tree are poisoned and freed" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const result_gpa = testing.allocator; // leaks here fail the test automatically
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    // MEDIUM-1 (D4 acceptance review): the io-side leak check must run on
    // ERROR paths too, not only at the bottom of a fully successful run.
    // This errdefer is declared BEFORE any io owner acquires anything, so
    // LIFO order runs it LAST — after every io_gpa dependent has been freed
    // back through poison. `dbg_released` closes the double-deinit window:
    // once the explicit success-path check below has taken ownership, an
    // error from that very assertion must not run deinit a second time.
    // errdefer context cannot `try`, so the error path reports a residual
    // leak loudly and non-fatally (the error that brought us here is
    // already the test's outcome).
    var dbg_released = false;
    errdefer if (!dbg_released) {
        if (dbg.deinit() != .ok) std.debug.print("T-LIFETIME: io DebugAllocator leaked on the error path\n", .{});
    };
    var poison: PoisonAllocator = .{ .child = dbg.allocator() };
    const io_gpa = poison.allocator();

    const src = "(cat (pure \"alpha\") (pure :kw) (pure sym) (pure 0.5))";
    var result: Result = blk: {
        // Error-path cleanup contract (MEDIUM-1, comment corrected to match
        // the code): EVERY acquired object carries an errdefer — including
        // the query's own `r`, registered the moment it exists — so a failed
        // pin unwinds r → p → bytes → tree (LIFO: dependents first), and
        // only then the io DebugAllocator check above runs. `decoded` needs
        // none — `fromTree` consumes it on the success AND error paths. On
        // the success path the explicit teardowns below run and the block
        // exits normally: errdefers do not fire on a normal block exit, so
        // nothing is freed twice.
        var tree = try Parser.parse(io_gpa, src);
        errdefer tree.deinit();
        var bytes = try Binary.toBinary(io_gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
        errdefer bytes.deinit();
        const decoded = try Binary.fromBinary(io_gpa, bytes.data, .{});
        var p = try PreparedBinary.fromTree(decoded);
        errdefer p.deinit();
        var r = try queryPreparedBinaryWithEnv(result_gpa, &p, patternSchema(), Span.init(0, 4 * PPC), 0, null);
        errdefer r.deinit(); // MEDIUM-1: a failed baseline pin must release the acquired Result

        // Live baseline BEFORE teardown: the exact literal expectations,
        // measured live 2026-10-21 (d4-probe-out.log) — `cat` lays its four
        // leaves across the window in sequence, one hap per leaf total.
        try testing.expectEqual(@as(usize, 4), r.haps.len);
        try testing.expectEqual(@as(usize, 0), r.dropped);
        try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
        try testing.expectEqualStrings("alpha", r.haps[0].value.string);
        try testing.expectEqualStrings("kw", r.haps[1].value.keyword);
        try testing.expectEqualStrings("sym", r.haps[2].value.symbol);
        try testing.expect(r.haps[3].value.eql(.{ .number = 0.5 }));
        try testing.expectEqual(@as(i64, 0), r.haps[0].timing.part.begin);
        try testing.expectEqual(PPC, r.haps[0].timing.part.end);
        try testing.expectEqual(PPC, r.haps[1].timing.part.begin);
        try testing.expectEqual(2 * PPC, r.haps[1].timing.part.end);
        try testing.expectEqual(2 * PPC, r.haps[2].timing.part.begin);
        try testing.expectEqual(3 * PPC, r.haps[2].timing.part.end);
        try testing.expectEqual(3 * PPC, r.haps[3].timing.part.begin);
        try testing.expectEqual(4 * PPC, r.haps[3].timing.part.end);

        // Teardown order: the result OUTLIVES everything it was computed
        // from. Each deinit forwards frees through the poison allocator.
        // No fallible statement follows the manual teardowns — the block
        // exits via `break` immediately, so the errdefers above can never
        // fire after them and nothing is freed twice.
        p.deinit(); // prepared tree (io_gpa) — poisoned on free
        tree.deinit(); // the ORIGINAL parse tree — poisoned on free
        bytes.deinit(); // the input wire bytes — poisoned on free
        break :blk r;
    };
    defer result.deinit();

    // AFTER poison+free: the actual Result's OWN fields (no copy, no
    // fingerprint) must still hold the exact bytes and timings.
    try testing.expectEqual(@as(usize, 4), result.haps.len);
    try testing.expectEqual(@as(usize, 0), result.dropped);
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try testing.expectEqualStrings("alpha", result.haps[0].value.string);
    try testing.expectEqualStrings("kw", result.haps[1].value.keyword);
    try testing.expectEqualStrings("sym", result.haps[2].value.symbol);
    try testing.expect(result.haps[3].value.eql(.{ .number = 0.5 }));
    try testing.expectEqual(@as(i64, 0), result.haps[0].timing.part.begin);
    try testing.expectEqual(4 * PPC, result.haps[3].timing.part.end);

    // The poison frees really executed (tree + bytes + prepared all released).
    try testing.expect(poison.poisoned_frees > 0);
    dbg_released = true; // the explicit check below owns the io teardown now
    try testing.expectEqual(.ok, dbg.deinit()); // io side leak-free (success path)
}

// ---- T-SWEEP: OOM sweeps — alloc AND resize channels, prepare AND query legs (D4) ----
//
// Ported from the executed spike's sweep discipline (spike30-runner.zig
// :822-941 — provenance, not a dependency) with the four production
// corrections of plan D4 Step 3: (i) the query legs' resize channel is swept
// (fired detection by `resize_index` shortfall — std's FailingAllocator sets
// `has_induced_failure` on the ALLOC channel only, so a resize refusal can
// never be detected through it); (ii) every counter accumulates into a test
// failure and ANY error without an induced failure fails loudly; (iii) counts
// are trip-wire pins of measured runs; (iv) sweep bounds are observed + 2,
// never derived.
//
// std FailingAllocator semantics (0.16, std/testing/FailingAllocator.zig,
// read 2026-10-21): `fail_index` is sticky — the alloc at that index fails
// and every later alloc fails too (alloc_index stops advancing);
// `resize_fail_index` is a separate channel shared by resize AND remap,
// equally sticky; neither channel touches the other's counters. A resize
// refusal may therefore be legitimately recovered by std's
// allocate-copy-free fallback while the alloc channel is unarmed.

const SweepCounts = struct {
    propagated: usize = 0, // error.OutOfMemory with an induced alloc failure
    swallowed: usize = 0, // success while an induced alloc failure had fired
    nonoom: usize = 0, // non-OOM error with an induced alloc failure
    clean: usize = 0, // success with no induced alloc failure
    mismatched: usize = 0, // HIGH-1: success whose outcome ≠ the fixed oracle
    leaked_rows: usize = 0, // the row's DebugAllocator reported a leak at deinit
};

test "prepared: OOM sweeps — alloc+resize channels, prepare+query legs, loud on the unknown" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    const env = testEnvBase3();
    const window = Span.init(0, PPC);

    // Dense-expr fixture (the spike's sweep fixture). ONE prepared object and
    // the original tree serve the whole query-leg sweep — reuse after failure
    // is part of the contract and is re-verified post-sweep.
    const src = try buildDenseExprSource(gpa);
    defer gpa.free(src);
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bytes.deinit();
    const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
    var p = try PreparedBinary.fromTree(decoded);
    defer p.deinit();

    // ---- clean counts, measured not derived (each on a fresh pair) -------
    var dbg_c: std.heap.DebugAllocator(.{}) = .init;
    var fa_c = std.testing.FailingAllocator.init(dbg_c.allocator(), .{});
    {
        const dec = try Binary.fromBinary(fa_c.allocator(), bytes.data, .{});
        var pc = try PreparedBinary.fromTree(dec);
        pc.deinit();
    }
    const n_prep_allocs = fa_c.allocations;
    const n_prep_resizes = fa_c.resize_index;
    try testing.expectEqual(.ok, dbg_c.deinit());
    // observed on pinned std 0.16.0 / 2026-10-21 — a deliberate change re-pins deliberately
    try testing.expectEqual(@as(usize, 11), n_prep_allocs);
    try testing.expectEqual(@as(usize, 0), n_prep_resizes);

    var dbg_p: std.heap.DebugAllocator(.{}) = .init;
    var fa_p = std.testing.FailingAllocator.init(dbg_p.allocator(), .{});
    {
        var rp = try queryPreparedBinaryWithEnv(fa_p.allocator(), &p, patternSchema(), window, 0, &env);
        rp.deinit();
    }
    const p_allocs = fa_p.allocations;
    const p_resizes = fa_p.resize_index;
    try testing.expectEqual(.ok, dbg_p.deinit());

    var dbg_t: std.heap.DebugAllocator(.{}) = .init;
    var fa_t = std.testing.FailingAllocator.init(dbg_t.allocator(), .{});
    {
        var rt = try queryTreeWithEnv(fa_t.allocator(), &tree, tree.root[0], patternSchema(), window, 0, &env);
        rt.deinit();
    }
    const t_allocs = fa_t.allocations;
    const t_resizes = fa_t.resize_index;
    try testing.expectEqual(.ok, dbg_t.deinit());

    // the identity claim's count axis: both arms must agree exactly
    try testing.expectEqual(t_allocs, p_allocs);
    try testing.expectEqual(t_resizes, p_resizes);
    // observed on pinned std 0.16.0 / 2026-10-21 — a deliberate change re-pins deliberately
    try testing.expectEqual(@as(usize, 24), p_allocs);
    try testing.expectEqual(@as(usize, 3), p_resizes);

    // ---- fixed outcome oracle (D4 review HIGH-1) --------------------------
    // Every successful sweep row below — a clean bound row or a
    // resize-refused allocate-copy-free fallback — must match THIS outcome.
    // It is computed ONCE, on the testing.allocator (`gpa`), from the
    // ORIGINAL parsed tree (the decoded wire form was consumed by
    // `fromTree`; no re-substitute is decoded), strictly OUTSIDE every
    // metered row: no FailingAllocator/DebugAllocator count or pin measured
    // above is perturbed, and the oracle outlives all sweeps.
    var oracle = try queryTreeWithEnv(gpa, &tree, tree.root[0], patternSchema(), window, 0, &env);
    defer oracle.deinit();

    // ---- prepare leg: alloc channel sweep (observed + 2 rows) ------------
    {
        var c: SweepCounts = .{};
        var loud_err: ?anyerror = null; // an error with NO induced failure — surfaced after the row's teardown
        var fi: usize = 0;
        while (fi <= n_prep_allocs + 1) : (fi += 1) {
            var dbg: std.heap.DebugAllocator(.{}) = .init;
            var fa = std.testing.FailingAllocator.init(dbg.allocator(), .{ .fail_index = fi });
            if (Binary.fromBinary(fa.allocator(), bytes.data, .{})) |dec| {
                var pc = try PreparedBinary.fromTree(dec);
                pc.deinit();
                if (fa.has_induced_failure) c.swallowed += 1 else c.clean += 1;
            } else |e| {
                if (!fa.has_induced_failure) {
                    std.debug.print("prepare alloc row fi={d}: unexpected error {s} with NO induced failure\n", .{ fi, @errorName(e) });
                    loud_err = e; // loud — never ignored; surfaced below, post-teardown
                } else if (e == error.OutOfMemory) {
                    c.propagated += 1;
                } else {
                    c.nonoom += 1;
                }
            }
            if (dbg.deinit() != .ok) c.leaked_rows += 1;
            if (loud_err) |e| return e; // every diagnostic allocator released first
        }
        try testing.expectEqual(@as(usize, 0), c.swallowed); // an induced OOM may never be swallowed
        try testing.expectEqual(@as(usize, 0), c.nonoom); // an induced failure may only surface as OutOfMemory
        try testing.expectEqual(n_prep_allocs, c.propagated); // every armed row propagates
        try testing.expectEqual(@as(usize, 2), c.clean); // exactly the two unarmed bound rows succeed
        try testing.expectEqual(@as(usize, 0), c.leaked_rows); // error paths clean every acquired object
    }

    // ---- prepare leg: resize channel (observed 0 attempts → arm unexercised)
    // There is no resize to refuse on this leg (measured 0 above), so the
    // refusal arm is explicitly UNEXERCISED here, not failure-tested: the two
    // bound rows must run clean with an armed but never-fired resize channel.
    {
        var ri: usize = 0;
        while (ri <= n_prep_resizes + 1) : (ri += 1) {
            var dbg: std.heap.DebugAllocator(.{}) = .init;
            var fa = std.testing.FailingAllocator.init(dbg.allocator(), .{ .resize_fail_index = ri });
            const dec = try Binary.fromBinary(fa.allocator(), bytes.data, .{});
            var pc = try PreparedBinary.fromTree(dec);
            pc.deinit();
            try testing.expectEqual(@as(usize, 0), fa.resize_index); // never fired — there was nothing to refuse
            try testing.expectEqual(.ok, dbg.deinit());
        }
    }

    // ---- query leg, prepared arm: alloc channel sweep ---------------------
    {
        var c: SweepCounts = .{};
        var loud_err: ?anyerror = null; // an error with NO induced failure — surfaced after the row's teardown
        var fi: usize = 0;
        while (fi <= p_allocs + 1) : (fi += 1) {
            var dbg: std.heap.DebugAllocator(.{}) = .init;
            var fa = std.testing.FailingAllocator.init(dbg.allocator(), .{ .fail_index = fi });
            if (queryPreparedBinaryWithEnv(fa.allocator(), &p, patternSchema(), window, 0, &env)) |res| {
                var r = res;
                if (expectSameOutcome(&oracle, &r)) {
                    if (fa.has_induced_failure) c.swallowed += 1 else c.clean += 1;
                } else |e| {
                    c.mismatched += 1; // HIGH-1: surfaced via the sweep pins below
                    std.debug.print("prepared alloc row fi={d}: clean-row outcome ≠ oracle ({s})\n", .{ fi, @errorName(e) });
                }
                r.deinit();
            } else |e| {
                if (!fa.has_induced_failure) {
                    std.debug.print("prepared alloc row fi={d}: unexpected error {s} with NO induced failure\n", .{ fi, @errorName(e) });
                    loud_err = e; // loud — never ignored; surfaced below, post-teardown
                } else if (e == error.OutOfMemory) {
                    c.propagated += 1;
                } else {
                    c.nonoom += 1;
                }
            }
            if (dbg.deinit() != .ok) c.leaked_rows += 1;
            if (loud_err) |e| return e; // every diagnostic allocator released first
        }
        try testing.expectEqual(@as(usize, 0), c.swallowed);
        try testing.expectEqual(@as(usize, 0), c.nonoom);
        try testing.expectEqual(p_allocs, c.propagated);
        try testing.expectEqual(@as(usize, 2), c.clean);
        try testing.expectEqual(@as(usize, 0), c.mismatched); // HIGH-1: bound-row successes ≡ oracle
        try testing.expectEqual(@as(usize, 0), c.leaked_rows);
    }

    // ---- query leg, prepared arm: resize channel sweep --------------------
    // The refusal is sticky: rows ri < p_resizes fire it (detected by the
    // `resize_index` shortfall); rows beyond the observed count cannot. A
    // fired row may legitimately SUCCEED — std's resize-failure fallback is
    // allocate-copy-free — and when it does, its outcome is verified against
    // the fixed oracle BEFORE teardown (HIGH-1). MEDIUM-2: an error row must
    // be error.OutOfMemory AND the refusal must have fired IN THAT ROW —
    // `fired` is determined per row from the actual `resize_index` shortfall
    // against the observed clean count, cross-checked against the armed
    // index, so a blanket-OOM regression on the unarmed bound rows lands in
    // `uninduced` and trips on its own; it can no longer pass because other
    // rows fired. Unknown errors are loud regardless of firing. Every
    // classification is surfaced only after the row's Result and
    // DebugAllocator have been released — no assertion propagates before its
    // diagnostic allocator is torn down.
    {
        var fired: usize = 0;
        var ok_rows: usize = 0;
        var oom_rows: usize = 0; // OutOfMemory AND the refusal fired in this row
        var uninduced: usize = 0; // OutOfMemory with NO refusal fired in this row
        var unknown: usize = 0; // non-OOM error, regardless of firing
        var mismatched: usize = 0;
        var crosscheck: usize = 0; // shortfall detector ≠ armed index — harness integrity
        var leaked_rows: usize = 0;
        var ri: usize = 0;
        while (ri <= p_resizes + 1) : (ri += 1) {
            var dbg: std.heap.DebugAllocator(.{}) = .init;
            var fa = std.testing.FailingAllocator.init(dbg.allocator(), .{ .resize_fail_index = ri });
            var oom_here = false;
            if (queryPreparedBinaryWithEnv(fa.allocator(), &p, patternSchema(), window, 0, &env)) |res| {
                var r = res;
                if (expectSameOutcome(&oracle, &r)) {
                    ok_rows += 1;
                } else |e| {
                    mismatched += 1; // surfaced via the sweep pins below, after teardown
                    std.debug.print("prepared resize row ri={d}: fallback outcome ≠ oracle ({s})\n", .{ ri, @errorName(e) });
                }
                r.deinit(); // ALWAYS released — mismatch or not
            } else |e| {
                if (e != error.OutOfMemory) {
                    unknown += 1; // loud regardless of firing — surfaced via the pins below
                    std.debug.print("prepared resize row ri={d}: unexpected error {s}\n", .{ ri, @errorName(e) });
                } else {
                    oom_here = true; // classification waits for this row's fired check
                }
            }
            const armed = ri < p_resizes;
            const fired_here = fa.resize_index < p_resizes; // actual shortfall vs the observed clean count
            if (fired_here) fired += 1;
            if (fired_here != armed) {
                crosscheck += 1;
                std.debug.print("prepared resize row ri={d}: shortfall {d} vs observed {d} disagrees with armed index\n", .{ ri, fa.resize_index, p_resizes });
            }
            if (oom_here) {
                if (fired_here) oom_rows += 1 else {
                    uninduced += 1;
                    std.debug.print("prepared resize row ri={d}: OutOfMemory with NO induced refusal in this row (resize_index={d}, observed={d})\n", .{ ri, fa.resize_index, p_resizes });
                }
            }
            if (dbg.deinit() != .ok) leaked_rows += 1;
        }
        // Per-row implications, aggregated — every counter bites (MEDIUM-2):
        try testing.expectEqual(@as(usize, 0), uninduced); // OOM only where the refusal actually fired
        try testing.expectEqual(@as(usize, 0), unknown); // success-or-OOM, never an unknown error
        try testing.expectEqual(@as(usize, 0), mismatched); // HIGH-1: every success ≡ the fixed oracle
        try testing.expectEqual(@as(usize, 0), crosscheck); // shortfall ⇔ armed index, always
        try testing.expectEqual(p_resizes, fired); // every armed row fired; both bound rows could not
        try testing.expectEqual(p_resizes + 2, ok_rows + mismatched + oom_rows + uninduced + unknown); // every row accounted, exactly one class
        try testing.expectEqual(@as(usize, 0), leaked_rows); // leaks never acceptable, fallback or not
    }

    // ---- query leg, tree arm: alloc channel sweep -------------------------
    {
        var c: SweepCounts = .{};
        var loud_err: ?anyerror = null; // an error with NO induced failure — surfaced after the row's teardown
        var fi: usize = 0;
        while (fi <= t_allocs + 1) : (fi += 1) {
            var dbg: std.heap.DebugAllocator(.{}) = .init;
            var fa = std.testing.FailingAllocator.init(dbg.allocator(), .{ .fail_index = fi });
            if (queryTreeWithEnv(fa.allocator(), &tree, tree.root[0], patternSchema(), window, 0, &env)) |res| {
                var r = res;
                if (expectSameOutcome(&oracle, &r)) {
                    if (fa.has_induced_failure) c.swallowed += 1 else c.clean += 1;
                } else |e| {
                    c.mismatched += 1; // HIGH-1: surfaced via the sweep pins below
                    std.debug.print("tree alloc row fi={d}: clean-row outcome ≠ oracle ({s})\n", .{ fi, @errorName(e) });
                }
                r.deinit();
            } else |e| {
                if (!fa.has_induced_failure) {
                    std.debug.print("tree alloc row fi={d}: unexpected error {s} with NO induced failure\n", .{ fi, @errorName(e) });
                    loud_err = e; // loud — never ignored; surfaced below, post-teardown
                } else if (e == error.OutOfMemory) {
                    c.propagated += 1;
                } else {
                    c.nonoom += 1;
                }
            }
            if (dbg.deinit() != .ok) c.leaked_rows += 1;
            if (loud_err) |e| return e; // every diagnostic allocator released first
        }
        try testing.expectEqual(@as(usize, 0), c.swallowed);
        try testing.expectEqual(@as(usize, 0), c.nonoom);
        try testing.expectEqual(t_allocs, c.propagated);
        try testing.expectEqual(@as(usize, 2), c.clean);
        try testing.expectEqual(@as(usize, 0), c.mismatched); // HIGH-1: bound-row successes ≡ oracle
        try testing.expectEqual(@as(usize, 0), c.leaked_rows);
    }

    // ---- query leg, tree arm: resize channel sweep ------------------------
    // Same discipline as the prepared arm (HIGH-1 + MEDIUM-2): successful
    // rows are verified against the fixed oracle before teardown; an OOM row
    // must have fired in that row; unknown errors are loud; every
    // classification surfaces only after the row's allocators are released.
    {
        var fired: usize = 0;
        var ok_rows: usize = 0;
        var oom_rows: usize = 0; // OutOfMemory AND the refusal fired in this row
        var uninduced: usize = 0; // OutOfMemory with NO refusal fired in this row
        var unknown: usize = 0; // non-OOM error, regardless of firing
        var mismatched: usize = 0;
        var crosscheck: usize = 0; // shortfall detector ≠ armed index — harness integrity
        var leaked_rows: usize = 0;
        var ri: usize = 0;
        while (ri <= t_resizes + 1) : (ri += 1) {
            var dbg: std.heap.DebugAllocator(.{}) = .init;
            var fa = std.testing.FailingAllocator.init(dbg.allocator(), .{ .resize_fail_index = ri });
            var oom_here = false;
            if (queryTreeWithEnv(fa.allocator(), &tree, tree.root[0], patternSchema(), window, 0, &env)) |res| {
                var r = res;
                if (expectSameOutcome(&oracle, &r)) {
                    ok_rows += 1;
                } else |e| {
                    mismatched += 1; // surfaced via the sweep pins below, after teardown
                    std.debug.print("tree resize row ri={d}: outcome ≠ oracle ({s})\n", .{ ri, @errorName(e) });
                }
                r.deinit(); // ALWAYS released — mismatch or not
            } else |e| {
                if (e != error.OutOfMemory) {
                    unknown += 1; // loud regardless of firing — surfaced via the pins below
                    std.debug.print("tree resize row ri={d}: unexpected error {s}\n", .{ ri, @errorName(e) });
                } else {
                    oom_here = true; // classification waits for this row's fired check
                }
            }
            const armed = ri < t_resizes;
            const fired_here = fa.resize_index < t_resizes; // actual shortfall vs the observed clean count
            if (fired_here) fired += 1;
            if (fired_here != armed) {
                crosscheck += 1;
                std.debug.print("tree resize row ri={d}: shortfall {d} vs observed {d} disagrees with armed index\n", .{ ri, fa.resize_index, t_resizes });
            }
            if (oom_here) {
                if (fired_here) oom_rows += 1 else {
                    uninduced += 1;
                    std.debug.print("tree resize row ri={d}: OutOfMemory with NO induced refusal in this row (resize_index={d}, observed={d})\n", .{ ri, fa.resize_index, t_resizes });
                }
            }
            if (dbg.deinit() != .ok) leaked_rows += 1;
        }
        try testing.expectEqual(@as(usize, 0), uninduced);
        try testing.expectEqual(@as(usize, 0), unknown);
        try testing.expectEqual(@as(usize, 0), mismatched);
        try testing.expectEqual(@as(usize, 0), crosscheck);
        try testing.expectEqual(t_resizes, fired);
        try testing.expectEqual(t_resizes + 2, ok_rows + mismatched + oom_rows + uninduced + unknown);
        try testing.expectEqual(@as(usize, 0), leaked_rows);
    }

    // ---- post-sweep reuse: the SAME prepared object answers clean and
    // remains ≡ the tree arm after every failing row above.
    var rp = try queryPreparedBinaryWithEnv(gpa, &p, patternSchema(), window, 0, &env);
    defer rp.deinit();
    var rt = try queryTreeWithEnv(gpa, &tree, tree.root[0], patternSchema(), window, 0, &env);
    defer rt.deinit();
    try expectSameOutcome(&rt, &rp);
    // the fixed oracle agrees with the live clean pair — three-way coherence
    try expectSameOutcome(&oracle, &rt);
    try expectSameOutcome(&oracle, &rp);
}

// ---- T-SEQUENCE: ordered child-request identity made observable (D4) --------
//
// Why the sequences MAY be compared (the approved structural argument, plan
// A.9, source-re-verified 2026-10-21): decode preserves node tags / child
// order / counts, per-occurrence string content (no interning on either
// side), and number-variant payload bits; pointer identity, `tree.source`
// slicing, spans, and comments are never consulted by compile or query. Same
// code (`queryTreeFull`) over logically equal trees on all allocation-relevant
// axes ⇒ the metered request sequence is identical. Counts alone (24==24)
// do not prove sequence identity, and sample equality is not an allocator
// monotonicity theorem — so this test asserts ELEMENT-WISE equality of the
// full ordered rows (kind, len, old_len, alignment, outcome) through the
// actual production query paths, original parsed tree vs prepared tree.
//
// The recorder's storage lives OUTSIDE the metered child and is reserved at
// fixed capacity BEFORE the query, so trace bookkeeping cannot perturb the
// sequence it records (no allocation reaches the metered child from the
// recorder; appends are plain stores into pre-owned memory). Each hook
// forwards first, then appends the full row including the forwarded call's
// outcome.

const Request = struct {
    op: enum { alloc, resize, remap, free },
    len: usize, // alloc: requested; resize/remap: NEW len; free: released
    old_len: usize = 0, // resize/remap: pre-call len (0 otherwise)
    alignment: std.mem.Alignment,
    ok: bool, // forwarded call's outcome (alloc/remap non-null / resize true)
};

const trace_capacity = 256; // observed run needs 54 — ample headroom, fixed

const RecordingAllocator = struct {
    child: std.mem.Allocator,
    rows: []Request, // owned by `log_gpa` — OUTSIDE the metered child
    n: usize = 0,
    log_gpa: std.mem.Allocator,

    fn init(child: std.mem.Allocator, log_gpa: std.mem.Allocator) !RecordingAllocator {
        const rows = try log_gpa.alloc(Request, trace_capacity);
        return .{ .child = child, .rows = rows, .log_gpa = log_gpa };
    }
    fn deinit(self: *RecordingAllocator) void {
        self.log_gpa.free(self.rows);
    }
    fn allocator(self: *RecordingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        } };
    }
    fn push(self: *RecordingAllocator, r: Request) void {
        // Fixed capacity reserved before the query: a full log is a test
        // bug (capacity is a pinned constant), never a mid-query allocation.
        std.debug.assert(self.n < self.rows.len);
        if (self.n < self.rows.len) {
            self.rows[self.n] = r;
            self.n += 1;
        }
    }
    fn allocFn(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *RecordingAllocator = @ptrCast(@alignCast(ptr));
        const res = self.child.rawAlloc(len, alignment, ra);
        self.push(.{ .op = .alloc, .len = len, .alignment = alignment, .ok = res != null });
        return res;
    }
    fn resizeFn(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *RecordingAllocator = @ptrCast(@alignCast(ptr));
        const ok = self.child.rawResize(memory, alignment, new_len, ra);
        self.push(.{ .op = .resize, .len = new_len, .old_len = memory.len, .alignment = alignment, .ok = ok });
        return ok;
    }
    fn remapFn(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *RecordingAllocator = @ptrCast(@alignCast(ptr));
        const res = self.child.rawRemap(memory, alignment, new_len, ra);
        self.push(.{ .op = .remap, .len = new_len, .old_len = memory.len, .alignment = alignment, .ok = res != null });
        return res;
    }
    fn freeFn(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *RecordingAllocator = @ptrCast(@alignCast(ptr));
        self.child.rawFree(memory, alignment, ra);
        self.push(.{ .op = .free, .len = memory.len, .alignment = alignment, .ok = true });
    }
};

test "prepared: ordered child-request sequence ≡ tree query's sequence (identity made observable)" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    const env = testEnvBase3();
    const window = Span.init(0, PPC);

    const src = try buildDenseExprSource(gpa);
    defer gpa.free(src);
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bytes.deinit();
    const decoded = try Binary.fromBinary(gpa, bytes.data, .{});
    var p = try PreparedBinary.fromTree(decoded);
    defer p.deinit();

    var dbg_rec_p: std.heap.DebugAllocator(.{}) = .init;
    var dbg_rec_t: std.heap.DebugAllocator(.{}) = .init;
    var rec_p = try RecordingAllocator.init(dbg_rec_p.allocator(), gpa);
    defer rec_p.deinit();
    var rec_t = try RecordingAllocator.init(dbg_rec_t.allocator(), gpa);
    defer rec_t.deinit();

    // both arms through the actual production entries, original parsed tree
    // vs prepared tree, each over its own fresh recording child whose child
    // is the same allocator family the sweeps meter (DebugAllocator — its
    // remap refusals and std's allocate-copy-free fallbacks are part of the
    // observed sequence; a remap-always-succeeds child would hide them)
    var rp = try queryPreparedBinaryWithEnv(rec_p.allocator(), &p, patternSchema(), window, 0, &env);
    var rt = try queryTreeWithEnv(rec_t.allocator(), &tree, tree.root[0], patternSchema(), window, 0, &env);
    try expectSameOutcome(&rt, &rp); // full outcome equality, not just shape
    rp.deinit(); // traces must be complete before the metered children die
    rt.deinit();

    // both metered children leak-free across the traced queries
    try testing.expectEqual(.ok, dbg_rec_p.deinit());
    try testing.expectEqual(.ok, dbg_rec_t.deinit());

    // both traces fit the frozen capacity (the recorder never grew mid-query)
    try testing.expect(rec_p.n <= trace_capacity);
    try testing.expect(rec_t.n <= trace_capacity);

    // trip-wire pin: observed on pinned std 0.16.0 / 2026-10-21 (env3, dense
    // expr, one cycle, DebugAllocator child) — a deliberate change re-pins
    // deliberately
    try testing.expectEqual(@as(usize, 54), rec_p.n);
    try testing.expectEqual(@as(usize, 54), rec_t.n);

    // per-op coherence inside each trace: 24 alloc requests and 6
    // resize-class requests (observed 2026-10-21). The 6 vs the sweep's
    // pinned 3 is not a contradiction: FailingAllocator.resize_index counts
    // successful resize/remaps only, while the trace counts REQUESTS — 3
    // remaps were refused by the DebugAllocator child and std's ArrayList
    // growth answered each refusal with allocate-copy-free (the extra alloc
    // requests are inside the 24).
    for ([2]*const RecordingAllocator{ &rec_p, &rec_t }) |rec| {
        var n_alloc: usize = 0;
        var n_resize_class: usize = 0;
        for (rec.rows[0..rec.n]) |r| switch (r.op) {
            .alloc => n_alloc += 1,
            .resize, .remap => n_resize_class += 1,
            .free => {},
        };
        try testing.expectEqual(@as(usize, 24), n_alloc);
        try testing.expectEqual(@as(usize, 6), n_resize_class);
    }

    // THE identity claim, element-wise: every row must match in op, len,
    // old_len, alignment, and outcome — not just the count.
    for (rec_p.rows[0..rec_p.n], rec_t.rows[0..rec_t.n], 0..) |a, b, i| {
        if (a.op != b.op or a.len != b.len or a.old_len != b.old_len or a.alignment != b.alignment or a.ok != b.ok) {
            std.debug.print("trace row {d} MISMATCH: prepared={{ {s} len={d} old={d} align={d} ok={} }} tree={{ {s} len={d} old={d} align={d} ok={} }}\n", .{ i, @tagName(a.op), a.len, a.old_len, @intFromEnum(a.alignment), a.ok, @tagName(b.op), b.len, b.old_len, @intFromEnum(b.alignment), b.ok });
        }
        try testing.expect(a.op == b.op);
        try testing.expect(a.len == b.len);
        try testing.expect(a.old_len == b.old_len);
        try testing.expect(a.alignment == b.alignment);
        try testing.expect(a.ok == b.ok);
    }
}
