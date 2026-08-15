//! Never-panic fuzz harnesses for the four byte-eating entrypoints.
//!
//! Each harness:
//!   * Generates an input via `std.testing.fuzz` + `Smith` (or runs the
//!     baked-in corpus when `zig build test` invokes it).
//!   * Feeds the input to the target function.
//!   * Asserts only invariants that must hold for ARBITRARY bytes — never
//!     "the parse succeeded" or "no diagnostics", since random bytes can
//!     trip every diagnostic.
//!
//! Shipped as a SEPARATE test target so the default `zig build test` stays
//! fast. Run as `zig build fuzz`. Each harness is also a normal `test {}`
//! so `zig build fuzz` exercises the corpus on every CI invocation.
//!
//! Invariants enforced:
//!   * `Lexer.next` terminates at `.eof` with `start == end == source.len`.
//!     For every emitted token, `end >= start`.
//!   * `Parser.parse` never panics; returns a `Tree` (possibly with
//!     diagnostics) or `error.OutOfMemory`. `tree.deinit()` succeeds.
//!   * `Json.fromJson` either returns a `Tree` or an error from the known
//!     `Json.Error` set; never panics, never leaks (testing.allocator
//!     catches leaks).
//!   * `Binary.fromBinary` either returns a `Tree` or an error from the
//!     known `Binary.Error` set; never panics, never leaks.
//!   * `Validator.validate` over `core.plugin` never panics on a parsed
//!     tree; only allocator failure surfaces. Every emitted diagnostic is
//!     iterable (well-formed `code`, `path`, `message`).
//!   * `Expr.eval` over `core.plugin` either returns a `Result` or an
//!     error from `Expr.Error`. Walks bound by `MAX_STEPS` /
//!     `MAX_EVAL_DEPTH`; never panics, never leaks.
//!   * `Edit.applyEditFromJsonString` either returns `Bytes` or an error
//!     from `Edit.Error` (= Edit's own variants ∪ `Json.Error`); never
//!     panics, never leaks. On success, the printed bytes parse cleanly.
//!   * `Edit.applyEditToTree` either returns a self-contained `Tree` or an
//!     error from `Edit.Error`; never panics, never leaks. The action is a
//!     pre-decoded `std.json.Value` — JSON parsing is the caller's job.

const std = @import("std");
// Through the module, not `@import("root.zig")`: the LSP harnesses below
// pull in `src/lsp/wasm.zig`, which reaches the core as `@import("sjon")`.
// A relative import here would compile a second, type-incompatible copy of
// the whole core into the same binary.
const sjon = @import("sjon");

const Lexer = sjon.Lexer;
const Parser = sjon.Parser;
const Json = sjon.Json;
const Binary = sjon.Binary;
const Validator = sjon.Validator;
const Expr = sjon.Expr;
const Edit = sjon.Edit;
const Schema = sjon.Schema;
const core = sjon.plugins.core;

const Smith = std.testing.Smith;
const testing = std.testing;

/// Maximum input size accepted by any harness. Keeps fuzzing cheap and
/// dodges Parser.MAX_PARSE_DEPTH / MAX_FILE_SIZE bounds — those have their own
/// dedicated tests.
const MAX_INPUT: usize = 1024;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Copy `bytes` into a sentinel-terminated, allocator-owned slice. Caller
/// frees with `gpa.free`. Returns `null` if `bytes` does not fit in the
/// stack buffer used by the harnesses (defensive — `MAX_INPUT` is checked
/// up-front by the caller).
fn toSentinel(gpa: std.mem.Allocator, bytes: []const u8) ![:0]u8 {
    const buf = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf;
}

const SeedOpts = struct {
    /// The harness's draw buffer size. A seed longer than this decodes to
    /// the EMPTY slice rather than being truncated — `Smith` falls back to
    /// the minimum permitted length when the encoded one is out of range —
    /// so the mismatch is asserted at comptime instead.
    cap: usize = MAX_INPUT,
    /// Little-endian `u64` records for the integer draws a harness makes
    /// *after* its slice. An absent tail is not an error: an exhausted
    /// stream yields each weight's minimum (0), which for a query window
    /// means the degenerate `[0, 0)`. Supply one where that would make the
    /// seed inert.
    tail: []const u64 = &.{},
};

/// Encode raw target inputs as `Smith` input streams.
///
/// `testing.FuzzInputOptions.corpus` entries are NOT handed to the harness
/// verbatim. They are `Smith`'s own encoded stream (`Smith.constructInput`
/// is the reference shape), and `sliceWithHash` reads a little-endian `u32`
/// length prefix off the front before copying that many bytes — see
/// `std/testing/Smith.zig:sliceWeightedWithHash`. A raw string therefore
/// reaches the target with its first four bytes reinterpreted as the length
/// and stripped: the seed `"(pure bd)"` arrives as `"e bd)"`, and anything
/// shorter than four bytes arrives empty.
///
/// That matters most in CI, where `builtin.fuzz` is false and the corpus is
/// the ONLY input each harness ever sees (`test_runner.fuzz`: "When the unit
/// test executable is not built in fuzz mode, only run the provided
/// corpus"). Under the instrumented fuzzer the encoding still matters — the
/// corpus seeds the mutator, so a malformed one starts it off the path the
/// seed was written to reach.
fn seeds(comptime raws: []const []const u8, comptime opts: SeedOpts) []const []const u8 {
    const encoded = comptime blk: {
        var out: [raws.len][]const u8 = undefined;
        for (raws, &out) |raw, *slot| {
            if (raw.len > opts.cap) @compileError("fuzz seed exceeds the harness draw buffer");
            var buf: [4 + raw.len + 8 * opts.tail.len]u8 = undefined;
            std.mem.writeInt(u32, buf[0..4], @intCast(raw.len), .little);
            @memcpy(buf[4..][0..raw.len], raw);
            for (opts.tail, 0..) |n, i| {
                std.mem.writeInt(u64, buf[4 + raw.len ..][8 * i ..][0..8], n, .little);
            }
            const frozen = buf;
            slot.* = &frozen;
        }
        break :blk out;
    };
    return &encoded;
}

test "seeds: a raw corpus entry reaches the harness intact" {
    // The bug this encoder exists for: `"(pure bd)"` used to arrive as
    // `"e bd)"`. Decoded here the way `Smith` decodes it.
    const encoded = seeds(&.{"(pure bd)"}, .{});
    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, encoded[0][0..4], .little));
    try testing.expectEqualStrings("(pure bd)", encoded[0][4..]);

    // A tail rides after the payload, one little-endian u64 per draw.
    const with_tail = seeds(&.{"x"}, .{ .tail = &.{ 7, 9 } });
    try testing.expectEqual(@as(usize, 4 + 1 + 16), with_tail[0].len);
    try testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, with_tail[0][5..13], .little));
    try testing.expectEqual(@as(u64, 9), std.mem.readInt(u64, with_tail[0][13..21], .little));

    // Sub-4-byte seeds are the ones the old shape erased entirely.
    const tiny = seeds(&.{ "", "ab" }, .{});
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, tiny[0][0..4], .little));
    try testing.expectEqualStrings("ab", tiny[1][4..]);
}

// ---------------------------------------------------------------------------
// 1. Lexer.next — token-stream invariants over arbitrary bytes.
// ---------------------------------------------------------------------------

fn fuzzLexer(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x10C000);
    if (len == 0) return;

    // Lexer requires a sentinel; copy into a sentinel-terminated stack buf.
    var sbuf: [MAX_INPUT + 1]u8 = undefined;
    @memcpy(sbuf[0..len], buf[0..len]);
    sbuf[len] = 0;
    const source: [:0]const u8 = sbuf[0..len :0];

    var lex = Lexer.init(source);
    var safety: u32 = 0;
    const safety_cap: u32 = @as(u32, @intCast(len)) + 4;

    while (safety < safety_cap) : (safety += 1) {
        const tok = lex.next();
        try testing.expect(tok.end >= tok.start);
        try testing.expect(tok.end <= source.len);
        if (tok.tag == .eof) {
            try testing.expectEqual(@as(u32, @intCast(source.len)), tok.start);
            try testing.expectEqual(@as(u32, @intCast(source.len)), tok.end);
            return;
        }
    }
    return error.LexerDidNotReachEof;
}

test "fuzz Lexer.next: terminates at .eof, end >= start" {
    try testing.fuzz({}, fuzzLexer, .{
        .corpus = seeds(&.{
            "",
            "()",
            "(scene :title \"x\")",
            "; comment\n(a)",
            "#| block |# (b)",
            "1.5e-3 -42 \"hi\\n\"",
            "\"unterminated",
            "(",
            ")",
            ":kw :foo bar",
            "()()()()",
            "((((((((((((((((((((((((((((((",
            "\xff\xfe\x00\x01\x02",
            // Unit-suffixed numbers exercise the new lexer states.
            "90deg 0.5em -50% 250ms 1.5e2hz",
            "1ex 1e9 1e9em 1.e2 1E-9em",
            "90deg5px 4PxRem 50%%",
            "1e+x",
            // Date literals — bounded lookahead in `.number_int`. Mix
            // valid and lookalike inputs so the fall-through paths
            // (`1900-1899` arithmetic, 5-digit years, underscores)
            // stay covered.
            "2026-05-19 0001-01-01 9999-12-31 2024-02-29",
            "1900-1899 2026-5-19 12345-06-07 2_026-05-19 -2026-05-19",
            // Time literals — bounded lookahead in `.number_int`. Mix
            // valid 8- and 12-char shapes with the fall-through cases
            // (`12:34` missing seconds, `12:34:5` 1-digit second,
            // `12:34:56.1` fractional too short).
            "12:34:56 00:00:00 23:59:59.999 12:34:56.789",
            "12:34 12:34:5 12:34:56.1 12:34:56.1234 1:34:56",
            // Raw multi-line strings — opener / body / close states,
            // including unterminated and quote-adjacent close forms.
            "\"\"\"hello\"\"\"",
            "\"\"\"\nmulti\nline\n\"\"\"",
            "\"\"\"\"abc\"\"\"",
            "\"\"\"contains \"single\" quote\"\"\"",
            "\"\"\"unterminated",
            "\"\"\"",
            "\"\"\"\"\"\"",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 2. Parser.parse — always returns a Tree (or OOM); never panics.
// ---------------------------------------------------------------------------

fn fuzzParser(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0xBADBEEF);

    const src = try toSentinel(testing.allocator, buf[0..len]);
    defer testing.allocator.free(src);

    var tree = Parser.parse(testing.allocator, src) catch |err| {
        // Only allocator failures are allowed to surface.
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer tree.deinit();

    // Tree must reference its source; root and diagnostics are arena-owned.
    try testing.expect(tree.source.len == src.len);
}

test "fuzz Parser.parse: returns a Tree, never panics" {
    try testing.fuzz({}, fuzzParser, .{
        .corpus = seeds(&.{
            "",
            "(a)",
            "(a (b (c)))",
            "(scene :title \"hi\" [1 2 3])",
            "; only comment\n",
            "((((",
            "))))",
            "(a :kw :other)",
            "(/qualified/head x y)",
            "1.5 -2 0xdeadbeef",
            "\"unterminated",
            "(a #| nested? |#)",
            // Date literal parser corpus — exercises the parser's
            // `Date.parse` path, the date diagnostic codes, and the
            // collection-over-abort fallback.
            "(release :date 2026-05-19)",
            "(invalid :leap 1900-02-29 :month 2026-13-01 :year 0000-01-01)",
            "[2026-05-19 0001-01-01 9999-12-31]",
            // Time literal parser corpus — exercises the parser's
            // `Time.parse` path, the time diagnostic codes, and the
            // collection-over-abort fallback.
            "(schedule :start 09:00:00 :end 17:30:00.500)",
            "(invalid :hour 24:00:00 :min 12:60:00 :sec 12:34:60)",
            "[00:00:00 12:34:56.789 23:59:59.999]",
            // Unit-suffixed parser corpus.
            "(scene :angle 90deg :delay 250ms)",
            "[4b 90deg 50% 250ms 0.5em 1.5e2hz]",
            "(let [r 0.5em] (vec3 r r r))",
            "100microseconds",
            // Raw multi-line strings as keyword values, vector elements,
            // and across mixed forms / unterminated cases.
            "(shader :code \"\"\"@vertex fn vs() {}\"\"\" )",
            "(t \"\"\"\nmulti\nline\n\"\"\")",
            "[\"\"\"a\"\"\" 1 \"\"\"b\"\"\"]",
            "(unterm :code \"\"\"oops",
            "(empty :s \"\"\"\"\"\")",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 3. Json.fromJson — either a Tree or one of Json.Error.
// ---------------------------------------------------------------------------

fn fuzzJsonFromJson(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0xC0FFEE);
    if (len == 0) return;

    // Try to parse the input bytes as JSON. Most random bytes fail JSON
    // parsing — that's fine, we only test fromJson for valid JSON values.
    var parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, buf[0..len], .{}) catch return;
    defer parsed.deinit();

    var tree = Json.fromJson(testing.allocator, parsed.value, .{}) catch |err| {
        // Allowed: any Json.Error variant. Anything else is a bug.
        switch (err) {
            error.OutOfMemory,
            error.MultipleRoots,
            error.InvalidEncoding,
            error.InvalidExprForm,
            error.InvalidFormHead,
            error.UnknownDiscriminator,
            error.DepthExceeded,
            => return,
        }
    };
    defer tree.deinit();
}

test "fuzz Json.fromJson: returns Tree or known error" {
    try testing.fuzz({}, fuzzJsonFromJson, .{
        .corpus = seeds(&.{
            "{}",
            "[]",
            "null",
            "0",
            "\"hi\"",
            "{\"$form\":\"a\"}",
            "{\"$form\":\"a\",\"$children\":[1,2]}",
            "{\"$kw\":\"foo\"}",
            "{\"$sym\":\"bar\"}",
            "{\"$roots\":[{\"$form\":\"a\"}]}",
            "{\"$unknown\":42}",
            "{\"$$escaped\":1}",
            "[1,2,{\"$form\":\"x\"}]",
            // $num discriminator corpus — accept and reject shapes.
            "{\"$num\":[90,\"deg\"]}",
            "{\"$num\":[0.5,\"em\"]}",
            "{\"$num\":[4]}",
            "{\"$num\":[90,99]}",
            "{\"$num\":[\"x\",\"deg\"]}",
            "{\"$num\":\"4b\"}",
            "{\"$num\":[]}",
            "{\"$num\":[90,\"\"]}",
            "{\"$$num\":1}",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 4. Binary.fromBinary — either a Tree or one of Binary.Error.
// ---------------------------------------------------------------------------

/// Exhaustive acknowledgement that every `Binary.Error` variant is an allowed
/// never-panic fuzz outcome. Purely a compile-time guard: adding a variant to
/// the binary error set breaks this switch, forcing the fuzz harnesses to
/// acknowledge the new outcome rather than silently treating it as a panic.
/// Sibling of `expectKnownEvalBinaryError` (which covers `Expr.BinaryError`).
/// `BinaryCursor.Error == Binary.Error`, so the cursor entrypoints share it.
fn expectKnownBinaryError(err: Binary.Error) void {
    switch (err) {
        error.OutOfMemory,
        error.InvalidMagic,
        error.InvalidVersion,
        error.InvalidFlags,
        error.InvalidTag,
        error.InvalidNamespace,
        error.Truncated,
        error.DepthExceeded,
        error.PoolIndexOutOfRange,
        error.NodeCountExceeded,
        error.StringTooLong,
        error.CommentTooLong,
        => {},
    }
}

fn fuzzBinaryFromBinary(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x5A1ADD);

    var tree = Binary.fromBinary(testing.allocator, buf[0..len], .{}) catch |err| {
        expectKnownBinaryError(err); // any Binary.Error variant is an allowed outcome
        return;
    };
    defer tree.deinit();
}

test "fuzz Binary.fromBinary: returns Tree or known error" {
    try testing.fuzz({}, fuzzBinaryFromBinary, .{
        .corpus = seeds(&.{
            "",
            // 16-byte zero header — bad magic.
            "\x00" ** 16,
            // Valid magic, zero version — invalid version.
            "SJ1\n\x00\x00\x00\x00" ++ "\x00\x00\x00\x00\x00\x00\x00\x00",
            // Truncated header.
            "SJ1\n",
            // Random short bytes.
            "deadbeef",
            "SJ1\n\x01\x00\x00\x00\x10\x00\x00\x00\x10\x00\x00\x00",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 5. BinaryCursor.init — never panics on arbitrary bytes.
//
// `Cursor.init` is the public read entrypoint for the streaming validator
// and evaluator. Random bytes must surface a documented error (or succeed
// trivially) without crashing.
// ---------------------------------------------------------------------------

const BinaryCursor = sjon.BinaryCursor;

fn fuzzBinaryCursorInit(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0xCC9501);

    var cursor = BinaryCursor.Cursor.init(buf[0..len]) catch |err| {
        expectKnownBinaryError(err);
        return;
    };
    // If init succeeded, calling rootIter must also produce a known error
    // or a valid iterator.
    _ = cursor.rootIter() catch |err| {
        expectKnownBinaryError(err);
        return;
    };
}

test "fuzz BinaryCursor.init: never panics on arbitrary bytes" {
    try testing.fuzz({}, fuzzBinaryCursorInit, .{
        .corpus = seeds(&.{
            "",
            "SJ1\n\x01\x00\x00\x00\x10\x00\x00\x00\x10\x00\x00\x00\x00\x00",
            "\x00" ** 16,
            "SJ1\n",
            // Bad pool offsets.
            "SJ1\n\x01\x00\x00\x00\x11\x00\x00\x00\x10\x00\x00\x00",
            // Magic but truncated below header.
            "SJ1\n\x01",
            // Reserved flag bits set.
            "SJ1\n\x01\xC0\x00\x00\x10\x00\x00\x00\x10\x00\x00\x00",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 6. Round-trip: parse → toBinary → fromBinary preserves root count.
//
// Whenever the parser produces a clean tree, the binary encode/decode
// pipeline must agree on the structural skeleton — root count is the
// cheapest invariant to enforce on any input.
// ---------------------------------------------------------------------------

fn fuzzParseEncodeDecode(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x500B112);

    const src = try toSentinel(testing.allocator, buf[0..len]);
    defer testing.allocator.free(src);

    var tree = Parser.parse(testing.allocator, src) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer tree.deinit();

    // Skip trees with parse diagnostics — round-trip semantics are only
    // claimed for well-formed inputs.
    if (tree.hasErrors()) return;

    const bin = Binary.toBinary(testing.allocator, tree, .{}) catch |err| {
        expectKnownBinaryError(err);
        return;
    };
    defer bin.deinit();

    var rebuilt = Binary.fromBinary(testing.allocator, bin.data, .{}) catch |err| {
        expectKnownBinaryError(err);
        return;
    };
    defer rebuilt.deinit();

    try testing.expectEqual(tree.root.len, rebuilt.root.len);
}

test "fuzz parse → toBinary → fromBinary: preserves root count for clean trees" {
    try testing.fuzz({}, fuzzParseEncodeDecode, .{
        .corpus = seeds(&.{
            "",
            "1",
            "1 2 3",
            "(a)",
            "(scene :bpm 130)",
            "[1 2 3]",
            "(scene :angle 90deg)",
            "(let [r 0.5em] (vec3 r r r))",
            "(a b c d e f g h i j)",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 7. Validator.validate — never panics on any parsed tree; only OOM surfaces.
//
// The validator walks an `Ast.Tree` against a schema and accumulates
// diagnostics. Its only declared error is `Allocator.Error` (Tree path).
// Random source bytes parse into a tree (possibly riddled with
// diagnostics from the parser) — feeding that tree into `validate` must
// still succeed and produce a well-formed `Result`.
// ---------------------------------------------------------------------------

fn fuzzValidator(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0xC0DE_5C);

    const src = try toSentinel(testing.allocator, buf[0..len]);
    defer testing.allocator.free(src);

    var tree = Parser.parse(testing.allocator, src) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer tree.deinit();

    const schema = Schema.Schema.init(&.{core.plugin});
    var result = Validator.validate(testing.allocator, tree, schema) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer result.deinit();

    // Diagnostics array must be iterable end-to-end without crashing —
    // touching every field forces the layout to be intact (catches UB
    // from a corrupted slice header that would slip past a bare length
    // check). The path is allowed to be empty (root-level diagnostic).
    for (result.diagnostics) |d| {
        try testing.expect(d.span.end >= d.span.start);
        for (d.path) |step| {
            // Touching `step.len` forces the slice header to be valid;
            // empty path steps are not valid (would indicate a bug).
            try testing.expect(step.len > 0);
        }
        // `code` is a Zig enum — invalid integers would already have
        // panicked by now; this read pins the contract.
        _ = d.code;
        _ = d.severity;
    }
}

test "fuzz Validator.validate: parsed tree always produces well-formed Result" {
    try testing.fuzz({}, fuzzValidator, .{
        .corpus = seeds(&.{
            // Empty / minimal.
            "",
            "nil",
            // Bare expression heads (resolved via core).
            "(+ 1 2)",
            "(if true 1 2)",
            "(let [x 1] (+ x 1))",
            // Schema-unknown form heads — exercises unknown_form path.
            "(scene :title \"hi\")",
            "(track :name p0 [1 2 3])",
            // Cross-ref shapes that the validator's index-builder walks.
            "(:cross-ref :name foo) (:cross-ref :target foo)",
            // Diagnostic-rich parse outputs (greedy keyword pairing,
            // unterminated strings, etc.).
            "(:k :v)",
            "(",
            "\"unterm",
            // Expr-shaped errors (arity / type) — eval rejects them, but
            // validate just walks structurally.
            "(+ \"a\" \"b\")",
            "(/ 1 0)",
            // Deep nesting (well below MAX_PARSE_DEPTH).
            "((((((((((+ 1 2))))))))))",
            // Vector / kvpair mixing.
            "[1 2 3 :k v]",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 8. Expr.eval — never panics on a clean parsed tree; only Expr.Error surfaces.
//
// `eval` evaluates the safe-expression sublanguage. Random inputs that
// parse cleanly may still produce every Expr.Error variant (TypeMismatch,
// ArityMismatch, UnknownFunction, …) — the harness asserts none escape
// the documented set.
//
// We restrict to clean trees because eval over a parser-recovery tree
// would read placeholder children whose semantic meaning is undefined —
// not a panic risk, but not a meaningful invariant either. The parser
// fuzz harness already covers the "random bytes → no panic" claim for
// the parse side.
// ---------------------------------------------------------------------------

fn fuzzExpr(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0xE7_E0_CA_FE);

    const src = try toSentinel(testing.allocator, buf[0..len]);
    defer testing.allocator.free(src);

    var tree = Parser.parse(testing.allocator, src) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer tree.deinit();

    if (tree.hasErrors()) return;
    if (tree.root.len == 0) return;

    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Expr.Env = .{};

    var result = Expr.eval(
        testing.allocator,
        &tree,
        tree.root[0],
        &empty_env,
        schema,
    ) catch |err| {
        switch (err) {
            error.OutOfMemory,
            error.TypeMismatch,
            error.DivisionByZero,
            error.UnknownFunction,
            error.AmbiguousFunction,
            error.ArityMismatch,
            error.UnknownBinding,
            error.InvalidLetBinding,
            error.InvalidCondClause,
            error.InvalidBinderShape,
            error.KeywordInExpressionArgs,
            error.DepthExceeded,
            error.MemoryBudgetExceeded,
            error.PluginFuncNotImplemented,
            error.PluginFuncResultType,
            error.PluginFuncFailed,
            error.PluginFuncTrapped,
            error.PluginFuncAllocFailed,
            => return,
        }
    };
    defer result.deinit();

    // Touching the value forces the union tag to be valid; an invalid
    // tag would have crashed by now in safe build modes.
    _ = result.value;
}

test "fuzz Expr.eval: clean tree → Result or known Expr.Error" {
    try testing.fuzz({}, fuzzExpr, .{
        .corpus = seeds(&.{
            // Atoms — every Value kind eval can produce.
            "nil",
            "true",
            "false",
            "0",
            "3.14",
            "\"hi\"",
            ":kw",
            "[1 2 3]",
            // Core arithmetic / comparison surface.
            "(+ 1 2)",
            "(- 10 3)",
            "(* 2 3 4)",
            "(/ 100 4)",
            "(mod 10 3)",
            "(< 1 2)",
            "(= 3 3)",
            // Domain edges that are legal to *write* and fail at eval.
            // `(clamp x 10 0)` used to reach `std.math.clamp`'s
            // `lower <= upper` assert — a panic from a document no
            // validator pass can reject, because the bounds are runtime
            // values. It is `error.TypeMismatch` now; this seed is what
            // makes CI notice if that guard ever goes away, since with
            // `builtin.fuzz` false the corpus is the only input.
            "(clamp 5 10 0)",
            "(clamp 5 (sqrt -1) 10)",
            // Special forms.
            "(if true 1 2)",
            "(cond (< 1 2) :a true :b)",
            "(and 1 2 3)",
            "(or false false 7)",
            "(let [x 3 y 4] (+ x y))",
            // Higher-order binder forms — exercise the 5th BinderKind
            // dispatch (fold), the 4-arity / 2-symbol shape, the
            // `fold_capture_init` bridge on the binary path, and the
            // empty-xs identity-returns-init early exit.
            "(map [x] [1 2 3] (* x x))",
            "(filter [x] [1 -2 3] (> x 0))",
            "(any [x] [1 2 3] (> x 2))",
            "(all [x] [1 2 3] (> x 0))",
            "(fold [acc x] 0 [1 2 3 4] (+ acc x))",
            "(fold [acc x] 42 [] (+ acc x))",
            // Vec ops.
            "(vec3 1 2 3)",
            "(dot (vec3 1 2 3) (vec3 4 5 6))",
            "(length (vec3 0 3 4))",
            // Error paths.
            "(/ 1 0)",
            "(+ \"a\" 1)",
            "(unknown-fn 1 2)",
            "(let [bad])",
            // Qualified head dispatch.
            "(core/+ 1 2)",
            // Deep let chain (well below MAX_EVAL_DEPTH).
            "(let [a 1] (let [b a] (let [c b] (+ a b c))))",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 8b. Expr.evalBinary — never panics on IR bytes (well-formed or hostile).
//
// evalBinary walks the binary IR directly — the read-only wasm artifact's
// entrypoint — so it must be as crash-proof as the tree evaluator, over two
// input shapes: (a) bytes we produce ourselves via parse -> toBinary, which
// drive the real form_walk / apply_form / binder binary frames; and (b) raw
// draws, almost none of which are valid IR, which must surface a documented
// BinaryError from the cursor rather than panicking. Its error set is
// `Expr.BinaryError` (Expr.Error + BinaryCursor.Error + MultipleRoots).
// ---------------------------------------------------------------------------

fn expectKnownEvalBinaryError(err: Expr.BinaryError) !void {
    switch (err) {
        error.OutOfMemory,
        error.TypeMismatch,
        error.DivisionByZero,
        error.UnknownFunction,
        error.AmbiguousFunction,
        error.ArityMismatch,
        error.UnknownBinding,
        error.InvalidLetBinding,
        error.InvalidCondClause,
        error.InvalidBinderShape,
        error.KeywordInExpressionArgs,
        error.DepthExceeded,
        error.MemoryBudgetExceeded,
        error.PluginFuncNotImplemented,
        error.PluginFuncResultType,
        error.PluginFuncFailed,
        error.PluginFuncTrapped,
        error.PluginFuncAllocFailed,
        error.InvalidMagic,
        error.InvalidVersion,
        error.InvalidFlags,
        error.InvalidTag,
        error.InvalidNamespace,
        error.Truncated,
        error.PoolIndexOutOfRange,
        error.NodeCountExceeded,
        error.StringTooLong,
        error.CommentTooLong,
        error.MultipleRoots,
        => {},
    }
}

fn fuzzEvalBinary(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0xE7_B1_11_A2);

    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Expr.Env = .{};

    // (b) Hostile-bytes variant: the raw draw is almost never a valid IR
    // buffer, so evalBinary must surface a documented BinaryError without
    // panicking (or leaking — testing.allocator would flag that).
    if (Expr.evalBinary(testing.allocator, buf[0..len], &empty_env, schema)) |res| {
        var r = res;
        r.deinit();
    } else |err| try expectKnownEvalBinaryError(err);

    // (a) Structured variant: bytes that parse cleanly are encoded to the
    // IR and evaluated, mirroring fuzzExpr through the binary reader.
    const src = try toSentinel(testing.allocator, buf[0..len]);
    defer testing.allocator.free(src);

    var tree = Parser.parse(testing.allocator, src) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer tree.deinit();

    if (tree.hasErrors()) return;
    if (tree.root.len == 0) return;

    const bin = Binary.toBinary(testing.allocator, tree, .{}) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer bin.deinit();

    var result = Expr.evalBinary(testing.allocator, bin.data, &empty_env, schema) catch |err| {
        try expectKnownEvalBinaryError(err);
        return;
    };
    defer result.deinit();

    // Touching the value forces a valid union tag; an invalid one would
    // have crashed by now in safe build modes.
    _ = result.value;
}

test "fuzz Expr.evalBinary: IR bytes → Result or known BinaryError" {
    try testing.fuzz({}, fuzzEvalBinary, .{
        .corpus = seeds(&.{
            // Valid sources — exercised through parse -> toBinary ->
            // evalBinary; their raw ASCII bytes also hit the hostile path.
            "(lerp :from 0 :to 10 :t 0.5)", // labeled call: the slot path
            "(lerp :t 0.5 :to 10 :from 0)", // out-of-order labels
            "(+ 1 2)",
            "(let [x 3 y 4] (+ x y))",
            "(fold [acc x] 0 [1 2 3 4] (+ acc x))",
            "(if true 1 2)",
            "(cond (< 1 2) :a true :b)",
            "(clamp 5 10 0)", // inverted range — see the tree harness
            "[1 2 3]",
            "12:34:56.789",
            "2026-07-03",
            // Hostile IR bytes for the raw evalBinary path.
            "",
            "SJ1\n",
            "SJ1\n\x01\x00\x00\x00\x10\x00\x00\x00\x10\x00\x00\x00",
            "deadbeef",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 9. Edit.applyEditFromJsonString — never panics on arbitrary (source, action).
//
// Most random byte pairs fail at JSON parse (`InvalidAction`) or path
// resolution (`InvalidPath` / `PathNotFound`). The corpus pins the
// success path for every op so the actual edit logic gets exercised.
//
// The single-input buffer is split: the leading byte selects an action
// template, the rest is the SJON source. This keeps the harness compatible
// with the same `sliceWithHash` shape as the other harnesses while still
// letting the fuzzer drive both sides of the input.
// ---------------------------------------------------------------------------

const edit_action_templates = [_][]const u8{
    "{\"op\":\"set_keyword\",\"path\":[],\"key\":\"x\",\"value\":1}",
    "{\"op\":\"set_keyword\",\"path\":[0],\"key\":\"a\",\"value\":\"hi\"}",
    "{\"op\":\"remove_keyword\",\"path\":[],\"key\":\"missing\"}",
    "{\"op\":\"replace\",\"path\":[0],\"value\":42}",
    "{\"op\":\"insert_positional\",\"path\":[],\"value\":7}",
    "{\"op\":\"insert_positional\",\"path\":[],\"value\":7,\"index\":0}",
    "{\"op\":\"remove_positional\",\"path\":[],\"index\":0}",
    // Intentionally malformed shapes — exercise the decoder rejects.
    "{\"op\":\"unknown\",\"path\":[]}",
    "{\"op\":\"replace\",\"path\":[],\"value\":1}", // empty path → InvalidPath
    "{}",
    "[]",
    "not json",
};

fn fuzzEdit(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0xED_17_F0_0D);
    if (len == 0) return;

    // First byte selects the action template; remainder is the source.
    const sel = buf[0] % edit_action_templates.len;
    const action_json = edit_action_templates[sel];
    const src_bytes = buf[1..len];

    const src = try toSentinel(testing.allocator, src_bytes);
    defer testing.allocator.free(src);

    var bytes = Edit.applyEditFromJsonString(
        testing.allocator,
        src,
        action_json,
        .{},
    ) catch |err| {
        switch (err) {
            // Edit's own variants.
            error.InvalidAction,
            error.InvalidPath,
            error.PathNotFound,
            error.PathTypeMismatch,
            error.EmptyTree,
            error.UnknownOp,
            // Json.Error variants (Edit re-exports the union).
            error.OutOfMemory,
            error.MultipleRoots,
            error.InvalidEncoding,
            error.InvalidExprForm,
            error.InvalidFormHead,
            error.UnknownDiscriminator,
            error.DepthExceeded,
            => return,
        }
    };
    defer bytes.deinit();

    // Successful edits must produce parseable SJON (the printer's
    // contract). Re-parse to confirm; the re-parsed tree may carry
    // diagnostics if the original input had them, but the parser must
    // not OOM on the printed output.
    const printed_src = try toSentinel(testing.allocator, bytes.data);
    defer testing.allocator.free(printed_src);
    var reparsed = Parser.parse(testing.allocator, printed_src) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer reparsed.deinit();
}

test "fuzz Edit.applyEditFromJsonString: returns Bytes or known Edit.Error" {
    try testing.fuzz({}, fuzzEdit, .{
        .corpus = seeds(&.{
            // Single-byte selector + small source. Each byte 0x00..0x0B
            // picks a different action template; the trailing source
            // covers the basic shapes (empty, single root, form, vector).
            "\x00(scene :a 1)",
            "\x01(scene :a 1 :b 2)",
            "\x02(scene :a 1)",
            "\x03(scene :a 1)",
            "\x04(scene 1 2 3)",
            "\x05(scene 1 2 3)",
            "\x06(scene 1 2 3)",
            "\x07(scene)",
            "\x08(scene)",
            "\x09(scene)",
            "\x0a(scene)",
            "\x0b(scene)",
            // Edge: empty source → EmptyTree.
            "\x00",
            // Edge: multi-root source → MultipleRoots.
            "\x00 1 2 3",
            // Vector at root.
            "\x03[1 2 3]",
            "\x06[1 2 3]",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 9. Lowering.runLoweringPass — never panics on any parsed tree; only OOM
//    surfaces, and every emitted diagnostic is well-formed.
//
// The lowering pass walks a parsed tree against a schema, fires registered
// hooks on lowerable forms, and runs the nested-lowerable lint over form-
// shaped children. Random source bytes parse into a tree (often diagnostic-
// riddled); driving that tree through the pass must still return a clean
// PassResult or error.OutOfMemory — never a panic, a malformed diagnostic, or
// a runaway. The static schema below declares a few lowerable heads so the
// corpus can actually reach the lint; Smith-random bytes mostly miss those
// heads, which is the point — the unknown-head and empty-head (parser-
// recovery) guard paths get hammered too. We also materialize the lowered
// tree, fuzzing the staging step the Host runs between layers.
// ---------------------------------------------------------------------------

/// Static schema for the lowering harness. Each lowerable head lowers via
/// `test/identity-v1` (emitting `<head>-normal`) and has a matching `:open`
/// terminal, so a clean nested document lowers without produced-head noise.
/// `node`/`wrap`/`leaf` are lowerable (self- and cross-nestable, to trip the
/// lint); `plain` is non-lowerable (the by-design nested-sugar parent).
const lowering_fuzz_plugin = sjon.Plugin.Plugin{
    .name = "fz",
    .forms = &.{
        .{ .name = "node", .open = true, .lowering = .{ .hook = "test/identity-v1", .produces = &.{"node-normal"} } },
        .{ .name = "wrap", .open = true, .lowering = .{ .hook = "test/identity-v1", .produces = &.{"wrap-normal"} } },
        .{ .name = "leaf", .open = true, .lowering = .{ .hook = "test/identity-v1", .produces = &.{"leaf-normal"} } },
        .{ .name = "plain", .open = true },
        .{ .name = "node-normal", .open = true },
        .{ .name = "wrap-normal", .open = true },
        .{ .name = "leaf-normal", .open = true },
    },
};

fn fuzzLowering(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x10E5_C0DE);

    const src = try toSentinel(testing.allocator, buf[0..len]);
    defer testing.allocator.free(src);

    var tree = Parser.parse(testing.allocator, src) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer tree.deinit();

    const schema = Schema.Schema.init(&.{ core.plugin, lowering_fuzz_plugin });

    var registry: sjon.Lowering.LoweringRegistry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, sjon.Lowering_test_hooks.test_identity_v1);

    // Empty overlay — the worklist walk and lint don't depend on materialized
    // defaults, and an empty one keeps the harness allocation-light.
    const overlay = sjon.MaterializedDefaults.MaterializedDefaults{};

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var pr = sjon.Lowering.runLoweringPass(
        testing.allocator,
        arena.allocator(),
        &tree,
        tree.root,
        schema,
        &overlay,
        &registry,
        .{},
    ) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer pr.deinit(testing.allocator);

    // Every emitted diagnostic must be structurally sound — the same contract
    // the validator harness pins: ordered span, non-empty path parts, a valid
    // enum tag and severity.
    for (pr.diagnostics) |d| {
        try testing.expect(d.span.end >= d.span.start);
        for (d.path) |step| try testing.expect(step.len > 0);
        _ = d.code;
        _ = d.severity;
    }

    // Staging materialization — build the lowered tree from the (input-derived)
    // invocations, the step the Host runs between layers. Must also never panic.
    var lowered = sjon.Lowering.buildLoweredTree(testing.allocator, pr.invocations, &tree) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer lowered.deinit();
}

test "fuzz Lowering.runLoweringPass: parsed tree always lowers to a well-formed PassResult" {
    try testing.fuzz({}, fuzzLowering, .{
        .corpus = seeds(&.{
            // Contradictory nested-lowerable shapes — the lint's positive space.
            "(node (node))",
            "(node (node (node)))",
            "(wrap (leaf))",
            "(node (node) (node))",
            "(node :slot (node))",
            "(node (fz/node))",
            // By-design nested sugar — plain parent, lowerable child (no lint).
            "(plain (node))",
            "(plain (node) (node))",
            // Mixed / adversarial nesting and depth.
            "(node (plain (node)))",
            "(node (leaf) :k (wrap))",
            "(wrap (wrap (wrap (wrap (wrap)))))",
            // Non-lowering shapes — unknown heads, scalars, vectors, exprs.
            "(scene :a 1)",
            "[1 2 3]",
            "(+ 1 2)",
            "nil",
            "",
            // Malformed / recovery — unterminated forms, empty-head recovery.
            "(",
            "(node (",
            "( (node))",
            "(node ())",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 11. PatternQuery — never panics; only PatternQuery.Error / BinaryError
// escape.
//
// `queryTree` interprets a parsed pattern over a fixed window. Random clean
// trees compile (atoms → pure, vectors → seq, combinator heads → their
// nodes) and query; the only escaping errors are the four bounded resource
// axes plus `TickOverflow` (a fast/slow factor that can't be localized to a
// node). `queryBinary` over arbitrary bytes must likewise never panic —
// either a `BinaryCursor` rejection, a resource bound, or a `Result`.
//
// A form in `(pure …)` value position is an `Expr` leaf: the corpus seeds
// several (modulation / sin / seeded rand / domain-hole / static defects), so
// mutation exercises the compile-time dry-run + the per-hap evaluator on the
// fixed scratch. That path never widens the escaping set — a per-hap eval
// failure is caught and counted, a static failure becomes a collected
// diagnostic — so the same five-axis `catch` stays exhaustive. The bare
// `query` entry that feeds `Expr` a null tree is unreachable here (every leaf
// comes from a real parsed tree).
// ---------------------------------------------------------------------------

const PatternQuery = sjon.PatternQuery;
const Pattern = sjon.Pattern;
const pattern_plugin = sjon.plugins.pattern;

fn patternFuzzSchema() Schema.Schema {
    return Schema.Schema.init(&.{ core.plugin, pattern_plugin.plugin });
}

/// Draw an arbitrary query window, ordered but otherwise unconstrained.
///
/// The window is user input on every host (`--begin=`/`--end=`, the
/// `sjon_query_pattern` export), and the walk uses unchecked tick arithmetic
/// internally — so the whole `i64` range has to be in the fuzzer's reach, not
/// just a fixed in-range span. Built field-wise rather than via `Span.init`,
/// whose `begin <= end` assert we satisfy here: that ordering *is* checked at
/// both real entries, magnitude was not.
fn fuzzWindow(smith: *Smith) Pattern.Span {
    const a = smith.valueWithHash(i64, 0x57_11_C0_DE);
    const b = smith.valueWithHash(i64, 0x57_11_C0_DF);
    return .{ .begin = @min(a, b), .end = @max(a, b) };
}

/// The window the pattern seeds are encoded with: four whole cycles from
/// tick 0. Both harnesses draw their window *after* the source slice, and an
/// exhausted stream hands back each weight's minimum — so with no tail every
/// seed would query the degenerate span `[0, 0)`, emit no haps, and exercise
/// nothing. See `SeedOpts.tail`.
const pattern_window_tail = [_]u64{ 0, @bitCast(@as(i64, 4 * Pattern.PPC)) };

fn fuzzPatternQueryTree(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x9A_77_E2_01);

    const src = try toSentinel(testing.allocator, buf[0..len]);
    defer testing.allocator.free(src);

    var tree = Parser.parse(testing.allocator, src) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer tree.deinit();

    if (tree.hasErrors()) return;
    if (tree.root.len == 0) return;

    var result = PatternQuery.queryTree(
        testing.allocator,
        &tree,
        tree.root[0],
        patternFuzzSchema(),
        fuzzWindow(smith),
        0,
    ) catch |err| {
        switch (err) {
            error.OutOfMemory,
            error.DepthExceeded,
            error.MemoryBudgetExceeded,
            error.HapBudgetExceeded,
            error.TickOverflow,
            => return,
        }
    };
    defer result.deinit();

    // Touch the result so an invalid union tag would crash here (safe build).
    for (result.haps) |h| _ = h.value;
    for (result.diagnostics) |d| _ = d.code;
}

test "fuzz PatternQuery.queryTree: clean tree → Result or known error" {
    try testing.fuzz({}, fuzzPatternQueryTree, .{
        .corpus = seeds(&.{
            // Leaves + implicit pure.
            "bd",
            "(pure bd)",
            "(pure 5)",
            "(silence)",
            "nil",
            // Vectors (fastcat) + nesting.
            "[bd sn]",
            "[[bd sn] hh]",
            "[bd [sn hh] cp]",
            "[]",
            // Combinators.
            "(fast 2 [bd sn])",
            "(slow 3 bd)",
            "(stack bd sn hh)",
            "(cat bd sn)",
            "(slowcat [bd sn] hh)",
            "(stack (fast 2 bd) (cat sn hh))",
            // Expr-valued leaves (a form in pure-value position): happy,
            // trig, seeded, runtime domain-hole, and the two static defects,
            // plus exprs under combinators so mutation reaches every arm.
            "(pure (+ 1 2))",
            "(pure (* 0.5 (+ 1 (sin (* (tau) cycle)))))",
            "(pure (rand01 seed cycle))",
            "(pure (/ 1 (- cycle 2)))",
            "(pure (+ nope 0))",
            "(pure (vec2 1 2))",
            "(fast 2 (pure (* cycle 2)))",
            "(stack (pure (sin cycle)) bd)",
            // Pathologies — overflow + degenerate factors + arity.
            "(fast 1000000000 (fast 1000000000 bd))",
            "(fast 0 bd)",
            "(fast -2 bd)",
            "(fast 1.5 bd)",
            "(pure)",
            "(fast 2)",
            // Malformed / recovery.
            "(",
            "(fast (",
            "",
        }, .{ .tail = &pattern_window_tail }),
    });
}

fn fuzzPatternQueryBinary(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x9A_77_E2_02);

    var result = PatternQuery.queryBinary(
        testing.allocator,
        buf[0..len],
        patternFuzzSchema(),
        fuzzWindow(smith),
        0,
    ) catch |err| {
        // PatternQuery.BinaryError = Error || BinaryCursor.Error || MultipleRoots.
        switch (err) {
            error.OutOfMemory,
            error.DepthExceeded,
            error.MemoryBudgetExceeded,
            error.HapBudgetExceeded,
            error.TickOverflow,
            error.MultipleRoots,
            error.InvalidMagic,
            error.InvalidVersion,
            error.InvalidFlags,
            error.InvalidTag,
            error.InvalidNamespace,
            error.Truncated,
            error.PoolIndexOutOfRange,
            error.NodeCountExceeded,
            error.StringTooLong,
            error.CommentTooLong,
            => return,
        }
    };
    defer result.deinit();
    for (result.haps) |h| _ = h.value;
}

test "fuzz PatternQuery.queryBinary: never panics on arbitrary bytes" {
    try testing.fuzz({}, fuzzPatternQueryBinary, .{
        .corpus = seeds(&.{
            "",
            "SJ1\n\x01\x00\x00\x00\x10\x00\x00\x00\x10\x00\x00\x00\x00\x00",
            "garbage",
            "\x00\x00\x00\x00\x00\x00\x00\x00",
        }, .{ .tail = &pattern_window_tail }),
    });
}

// ---------------------------------------------------------------------------
// 12. ManifestLoader.load — never panics on any parsed tree; only OOM or
//     NotAPluginManifest surfaces, and every emitted diagnostic is well-formed.
//
// `load` meta-validates the tree, then (only on a meta-clean tree) walks it
// into an owned `Plugin`. The walk deliberately skips the defensive checks
// meta-validation already performed, so feeding it a *parser-recovery* tree
// (parse diagnostics, partial forms) probes exactly that "assumes validated"
// seam — the same seam `Host.validateDocument` leans on per declaration.
// Random bytes almost always fail meta-validation (→ a diagnostic-carrying
// `Result`, never a panic); the manifest seeds drive the walk itself.
//
// Seeds are hand-written representative manifests, not the live corpus: `src/`
// can't `@embedFile` `conformance/cases/` (see `MetaSchema.zig`'s note), and
// `conformance_tests.zig` already replays every real `schema.sjon` structurally
// — this harness adds the *mutation* surface the largest module never had.
// ---------------------------------------------------------------------------

const ManifestLoader = sjon.ManifestLoader;

fn fuzzManifestLoader(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x8A_11_F0_AD);

    const src = try toSentinel(testing.allocator, buf[0..len]);
    defer testing.allocator.free(src);

    var tree = Parser.parse(testing.allocator, src) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer tree.deinit();

    var result = ManifestLoader.load(testing.allocator, tree) catch |err| {
        switch (err) {
            error.OutOfMemory,
            error.NotAPluginManifest,
            => return,
        }
    };
    defer result.deinit();

    // Every emitted diagnostic must be structurally sound — the same contract
    // the validator/lowering harnesses pin: ordered span, non-empty path
    // parts, a valid enum tag and severity.
    for (result.diagnostics) |d| {
        try testing.expect(d.span.end >= d.span.start);
        for (d.path) |step| try testing.expect(step.len > 0);
        _ = d.code;
        _ = d.severity;
    }

    // Touch the materialized plugin skeleton — empty (`.name = ""`, no forms)
    // when meta-validation rejected the manifest, populated otherwise. Reading
    // the slice headers forces them to be intact on both paths.
    _ = result.plugin.name.len;
    _ = result.plugin.forms.len;
}

test "fuzz ManifestLoader.load: parsed tree → Result or known error" {
    try testing.fuzz({}, fuzzManifestLoader, .{
        .corpus = seeds(&.{
            // Non-manifest roots — the reject-with-diagnostics path.
            "",
            "nil",
            "(scene :title \"hi\")",
            "[1 2 3]",
            "(+ 1 2)",
            // Minimal valid plugin.
            "(plugin :name p :version \"1.0.0\")",
            // Form + keys of assorted underlying types (reaches the walk).
            "(plugin :name ui :version \"1.0.0\"\n  (form :name canvas\n    (key :name w :type number :optional false)\n    (key :name title :type string :optional true)))",
            // value-kind with unit + numeric bounds (bounds_manifest_source).
            "(plugin :name p :version \"1.0.0\"\n  (form :name delay\n    (key :name wait :type duration :optional false))\n  (value-kind :name duration :underlying number\n    :unit (unit-shape :required true :allowed [ms])\n    :numeric (numeric-bounds :min 0ms :max 10000ms :exclusive-max true)))",
            // value-kind vector-shape + cross-ref (cross-ref-non-symbol-name).
            "(plugin :name xref :version \"1.0.0\"\n  (value-kind :name phrase-name :underlying symbol\n    :cross-ref (cross-ref :target phrase))\n  (value-kind :name phrase-sequence :underlying vector\n    :vector (vector-shape :element phrase-name))\n  (form :name phrase (key :name name :type symbol :optional false))\n  (form :name track (key :name sequence :type phrase-sequence :optional false)))",
            // Provider-route cross-ref: the `1.2` vocabulary in one seed —
            // a `(cross-ref-provider …)` catalog entry with a `wasm:` impl,
            // and a `(cross-ref …)` taking `:provider` + `:source-key`
            // instead of `:name-key`. The mutator's neighbourhood here is
            // the loader's exclusivity rules (both routes at once, a
            // `:source-key` with no `:provider`, `:acyclic` on the provider
            // route), which are cheap to reach from a well-formed anchor and
            // essentially unreachable from random bytes.
            "(plugin :name glsl :version \"1.0.0\" :sjon \"1.2\"\n  (cross-ref-provider :name lines :description \"one per line\" :impl \"wasm:extract_lines\")\n  (form :name shader (key :name name :type symbol :optional false) (key :name src :type string :optional false))\n  (value-kind :name uniform-name :underlying symbol\n    :cross-ref (cross-ref :target shader :provider lines :source-key src))\n  (form :name bind (key :name uniform :type uniform-name :optional false)))",
            // member-set value-kind (closed symbol set).
            "(plugin :name e :version \"1.0.0\"\n  (value-kind :name tag :underlying symbol\n    :members (member-set :values [a b c])))",
            // expr-func — mono signature.
            "(plugin :name fx :version \"1.0.0\"\n  (expr-func :name inc :arity (fixed 1) :params [number] :result number))",
            // slot-local nested forms (local_form_manifest_source).
            "(plugin :name ui2 :version \"1.0.0\"\n  (form :name canvas\n    (key :name shape :type form\n      (form :name circle (key :name r :type number :optional false))\n      (form :name rect (key :name w :type number :optional false)))))",
            // POSITIONAL slot-local forms (FormSpec.local_forms): inline `(form …)`
            // children directly under the parent `(form …)`. No `:positional` ⇒
            // implied `.any`; `group` nests BOTH carriers (a positional-local `leaf`
            // and a key-local `badge` on `:tag`) to exercise depth + composition.
            "(plugin :name plf :version \"1.0.0\"\n  (form :name bind-group\n    (form :name entry (key :name binding :type number :optional false))\n    (form :name buffer (key :name slot :type number :optional false))\n    (form :name group\n      (form :name leaf)\n      (key :name tag :type form (form :name badge)))))",
            // Malformed / adversarial — the meta-validator's reject space.
            "(plugin :name p)",
            "(plugin :version \"1.0.0\")",
            "(plugin :name 42 :version 1.0)",
            "(plugin :name p :version \"1.0.0\" (form))",
            "(plugin :name p :version \"1.0.0\" (key :name x :type bogus))",
            "(plugin",
            "(plugin :name p :version \"1.0.0\" (form :name f (",
            "(plugin :name p :version \"1.0.0\" :extra :junk)",
            // Positional locals conflicting with a `(flag-set …)` — the loader
            // rejects the combination (`invalid_manifest`), never panics.
            "(plugin :name plf-bad :version \"1.0.0\"\n  (form :name task\n    :positional (flag-set (flag :name done) (flag :name archived))\n    (form :name entry (key :name binding :type number :optional false))))",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 13. Host.validateDocument — never panics on arbitrary source; only OOM (its
//     single declared error) surfaces, and every diagnostic is well-formed.
//
// validateDocument is the inline-manifest constructor: parse source, partition
// roots into declarations / references / data-forest, load each inline
// `(plugin …)`, compose a schema, validate the data forms against it. Default
// `HostOptions` ⇒ no resolver, no filesystem, no `plugin_exec` runtime, so the
// whole pipeline is a deterministic function of the bytes. Random bytes mostly
// parse into recovery trees whose data forms hit the unknown-form / type paths
// and whose `(use-plugin …)` refs fail `unresolved_plugin` — all collected,
// never a panic. The seeds drive the full three-phase pipeline on clean docs.
// ---------------------------------------------------------------------------

const Host = sjon.Host;

fn fuzzHostValidateDocument(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x805_D0C_5A);

    const src = try toSentinel(testing.allocator, buf[0..len]);
    defer testing.allocator.free(src);

    var result = Host.validateDocument(testing.allocator, src, .{}) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer result.deinit();

    // Every host diagnostic must be structurally sound across all three
    // phases (manifest / aggregate / data): ordered span, non-empty path
    // parts, a valid enum tag / severity / phase.
    for (result.diagnostics) |d| {
        try testing.expect(d.span.end >= d.span.start);
        for (d.path) |step| try testing.expect(step.len > 0);
        _ = d.code;
        _ = d.severity;
        _ = d.phase;
    }

    // Touch the partition + loaded-plugin views so a corrupted slice header
    // would crash here rather than slip past a bare length read.
    _ = result.declarations.len;
    _ = result.references.len;
    _ = result.data_forest.len;
    for (result.plugins) |p| _ = p.name.len;
}

test "fuzz Host.validateDocument: arbitrary source → HostResult or OOM" {
    try testing.fuzz({}, fuzzHostValidateDocument, .{
        .corpus = seeds(&.{
            // Bare data / atoms — no declarations, data-forest only.
            "",
            "nil",
            "42",
            "\"hi\"",
            "[1 2 3]",
            "(+ 1 2)",
            "2026-05-19",
            "12:34:56.789",
            // Inline plugin declaration + conforming data (all three phases).
            "(plugin :name p :version \"1.0.0\"\n  (form :name box (key :name w :type number :optional false)))\n(box :w 5)",
            // Inline plugin + non-conforming data (data-phase diagnostic).
            "(plugin :name p :version \"1.0.0\"\n  (form :name box (key :name w :type number :optional false)))\n(box :w \"nope\")",
            // Inline plugin + missing required key.
            "(plugin :name p :version \"1.0.0\"\n  (form :name box (key :name w :type number :optional false)))\n(box)",
            // Unknown data-form heads (no declaration covers them).
            "(scene :title \"hi\") (canvas :w 320)",
            // use-plugin reference — unresolved with the default (null) resolver.
            "(use-plugin foo)\n(thing :x 1)",
            // Two inline plugins composed into one schema.
            "(plugin :name a :version \"1.0.0\" (form :name x (key :name n :type number :optional false)))\n(plugin :name b :version \"1.0.0\" (form :name y (key :name s :type string :optional false)))\n(x :n 1) (y :s \"ok\")",
            // Positional slot-local forms + conforming data — drives the validator's
            // local-first resolution (both `entry` and `buffer` resolve to the
            // `bind-group` locals) through the full three-phase pipeline.
            "(plugin :name plf :version \"1.0.0\"\n  (form :name bind-group\n    (form :name entry (key :name binding :type number :optional false))\n    (form :name buffer (key :name slot :type number :optional false))))\n(bind-group (entry :binding 0) (buffer :slot 1))",
            // Positional locals colliding with a `(flag-set …)` — manifest-phase
            // `invalid_manifest`, then the data form hits the unknown-form path.
            "(plugin :name plf-bad :version \"1.0.0\"\n  (form :name task\n    :positional (flag-set (flag :name done) (flag :name archived))\n    (form :name entry (key :name binding :type number :optional false))))\n(task :done)",
            // Provider-route cross-ref, declaration-only. Drives the whole
            // extraction join in one document: the pre-pass discovers the
            // `(provider, source)` pair, records it unrunnable, and the
            // index pass poisons the bucket so the reference below goes
            // unchecked. Declaration-only on purpose — no host running this
            // harness has a runtime, and the poisoned path is the one with
            // arms that random bytes never reach.
            "(plugin :name probe :version \"1.0.0\" :sjon \"1.2\"\n  (cross-ref-provider :name lines :description \"one per line\")\n  (form :name shader (key :name name :type symbol :optional false) (key :name src :type string :optional false))\n  (value-kind :name uniform-name :underlying symbol\n    :cross-ref (cross-ref :target shader :provider lines))\n  (form :name bind (key :name uniform :type uniform-name :optional false)))\n(shader :name main :src \"u_time\\nu_res\")\n(bind :uniform u_time)",
            // The same schema with two sources and no references — the
            // discovery walk's dedup arm (two distinct pairs) beside the
            // registration arm that never runs.
            "(plugin :name probe :version \"1.0.0\" :sjon \"1.2\"\n  (cross-ref-provider :name lines :description \"one per line\")\n  (form :name shader (key :name name :type symbol :optional false) (key :name src :type string :optional false))\n  (value-kind :name uniform-name :underlying symbol\n    :cross-ref (cross-ref :target shader :provider lines)))\n(shader :name a :src \"x\")\n(shader :name b :src \"x\")",
            // Malformed manifest declaration (manifest-phase diagnostic).
            "(plugin :name p)\n(box :w 1)",
            // Parser-recovery inputs.
            "(",
            "(plugin :name p :version \"1.0.0\" (form :name box (",
            "\"unterminated",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 14. SchemaExport.exportSchema — never panics on any loaded plugin, and the
//     emitted JSON Schema always re-parses as JSON.
//
// The exporter lowers a `Schema.Schema` into the `Model` IR and emits JSON
// Schema 2020-12 + a TypeScript `.d.ts`; its only declared error is OOM. This
// harness eats arbitrary bytes, loads them as a manifest, and — only when the
// load is clean — composes a one-plugin schema and exports both backends.
// Random bytes rarely load, so the manifest seeds (shared vocabulary with the
// loader harness) carry the export coverage while mutation explores the
// IR-lowering arms from those anchors. The JSON artifact is a machine
// contract, so we re-parse it: a malformed emit surfaces as a std.json error
// here (a real bug), never a panic.
// ---------------------------------------------------------------------------

const SchemaExport = sjon.SchemaExport;

fn fuzzSchemaExport(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x5C_EE_00_7E);

    const src = try toSentinel(testing.allocator, buf[0..len]);
    defer testing.allocator.free(src);

    var tree = Parser.parse(testing.allocator, src) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer tree.deinit();

    var loaded = ManifestLoader.load(testing.allocator, tree) catch |err| {
        switch (err) {
            error.OutOfMemory, error.NotAPluginManifest => return,
        }
    };
    defer loaded.deinit();

    // Only a cleanly-loaded plugin has a well-formed schema to export.
    if (loaded.hasErrors()) return;

    const plugins = [_]sjon.Plugin.Plugin{loaded.plugin};
    const schema = sjon.Schema.Schema.init(&plugins);

    var exported = SchemaExport.exportSchema(testing.allocator, schema, .{}) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer exported.deinit();

    // The JSON Schema artifact is a machine contract: it must re-parse. The
    // TS `.d.ts` has no cheap structural oracle, so touching its slice header
    // is enough to force the buffer intact.
    if (exported.json_schema_bytes) |json| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        parsed.deinit();
    }
    if (exported.ts_types_bytes) |ts| _ = ts.len;
}

test "fuzz SchemaExport.exportSchema: loaded plugin exports valid JSON" {
    try testing.fuzz({}, fuzzSchemaExport, .{
        .corpus = seeds(&.{
            // Non-loading — early return (exercises the load-reject guard).
            "",
            "(scene :title \"hi\")",
            "(plugin :name p)",
            // Loading manifests — drive both export backends + the JSON oracle.
            "(plugin :name p :version \"1.0.0\")",
            "(plugin :name ui :version \"1.0.0\"\n  (form :name box\n    (key :name w :type number :optional false)\n    (key :name title :type string :optional true)))",
            "(plugin :name p :version \"1.0.0\"\n  (form :name delay\n    (key :name wait :type duration :optional false))\n  (value-kind :name duration :underlying number\n    :unit (unit-shape :required true :allowed [ms])\n    :numeric (numeric-bounds :min 0ms :max 10000ms :exclusive-max true)))",
            "(plugin :name xref :version \"1.0.0\"\n  (value-kind :name phrase-name :underlying symbol\n    :cross-ref (cross-ref :target phrase))\n  (value-kind :name phrase-sequence :underlying vector\n    :vector (vector-shape :element phrase-name))\n  (form :name phrase (key :name name :type symbol :optional false))\n  (form :name track (key :name sequence :type phrase-sequence :optional false)))",
            "(plugin :name e :version \"1.0.0\"\n  (value-kind :name tag :underlying symbol\n    :members (member-set :values [a b c])))",
            "(plugin :name fx :version \"1.0.0\"\n  (expr-func :name inc :arity (fixed 1) :params [number] :result number))",
            "(plugin :name ui2 :version \"1.0.0\"\n  (form :name canvas\n    (key :name shape :type form\n      (form :name circle (key :name r :type number :optional false))\n      (form :name rect (key :name w :type number :optional false)))))",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 11. Edit.applyEditToTree — the tree-consuming edit path never panics on an
//     arbitrary (parsed tree, decoded action). Its source sibling
//     `applyEditFromJsonString` (harness 9) parses the action from bytes;
//     this one takes an already-decoded `std.json.Value`, so the harness
//     parses a template into a value first (a template that isn't valid JSON
//     simply isn't a candidate — JSON-parse rejection is the caller's job
//     here, not the edit's) and drives the decode + functional rebuild
//     directly. On success the returned tree is self-contained (Phase 2) and
//     deinits cleanly; the leak check rides testing.allocator.
//
// Reuses the harness-9 selector split (leading byte picks an action template,
// the rest is the SJON source) and the same exhaustive `Edit.Error` switch —
// `applyEditToTree` shares the error contract, so a new variant breaks this
// switch too.
// ---------------------------------------------------------------------------

fn fuzzEditToTree(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x7EED_7017);
    if (len == 0) return;

    // First byte selects the action template; remainder is the source.
    const sel = buf[0] % edit_action_templates.len;
    const action_json = edit_action_templates[sel];
    const src_bytes = buf[1..len];

    const src = try toSentinel(testing.allocator, src_bytes);
    defer testing.allocator.free(src);

    var tree = Parser.parse(testing.allocator, src) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer tree.deinit();

    // A malformed template can't be decoded into a value; skip it (the
    // JSON-parse reject is exercised by harness 9, not this entrypoint).
    var parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, action_json, .{}) catch return;
    defer parsed.deinit();

    var edited = Edit.applyEditToTree(testing.allocator, &tree, parsed.value) catch |err| {
        switch (err) {
            // Edit's own variants.
            error.InvalidAction,
            error.InvalidPath,
            error.PathNotFound,
            error.PathTypeMismatch,
            error.EmptyTree,
            error.UnknownOp,
            // Json.Error variants (Edit re-exports the union).
            error.OutOfMemory,
            error.MultipleRoots,
            error.InvalidEncoding,
            error.InvalidExprForm,
            error.InvalidFormHead,
            error.UnknownDiscriminator,
            error.DepthExceeded,
            => return,
        }
    };
    edited.deinit();
}

test "fuzz Edit.applyEditToTree: returns Tree or known Edit.Error" {
    try testing.fuzz({}, fuzzEditToTree, .{
        .corpus = seeds(&.{
            // Single-byte selector + small source (same shape as harness 9).
            "\x00(scene :a 1)",
            "\x01(scene :a 1 :b 2)",
            "\x02(scene :a 1)",
            "\x03(scene :a 1)",
            "\x04(scene 1 2 3)",
            "\x05(scene 1 2 3)",
            "\x06(scene 1 2 3)",
            "\x07(scene)",
            "\x08(scene)",
            "\x09(scene)",
            "\x0a(scene)",
            "\x0b(scene)",
            // Edge: empty source → EmptyTree.
            "\x00",
            // Edge: multi-root source.
            "\x00 1 2 3",
            // Vector at root.
            "\x03[1 2 3]",
            "\x06[1 2 3]",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 15. Host.validateDocument against a PRELOADED schema — the two-phase F9
//     entrypoint never panics, and the borrow of a stable preloaded schema
//     survives arbitrary document bytes.
//
// A fixed known-good manifest is preloaded once per input (its own load is
// deterministic and clean), then Smith bytes are validated against it via
// `HostOptions.preloaded`. Random bytes resolve the preloaded `box` form,
// trip unknown-form / type paths, or add their own inline plugin (additive —
// re-running the aggregate over the combined set, and colliding inline `box`
// vs preloaded `box` as `ambiguous_form`). Same structural invariant as
// harness 13, now over the preloaded borrow: every diagnostic across manifest
// / aggregate / data phases is well-formed, and `HostResult.deinit` (which
// must never touch the preloaded arenas) leaves no leak.
// ---------------------------------------------------------------------------

const host_preload_manifest = [_][:0]const u8{
    "(plugin :name pre :version \"1.0.0\"\n  (form :name box (key :name w :type number :optional false) (key :name label :type string :optional true)))",
};

fn fuzzHostPreloadedValidate(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x9E_10AD_5A);

    const src = try toSentinel(testing.allocator, buf[0..len]);
    defer testing.allocator.free(src);

    // Fixed known-good schema, preloaded once and borrowed by the document
    // pass. Only OOM can surface — the manifest itself is always clean.
    var pre = Host.preloadSchema(testing.allocator, &host_preload_manifest) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer pre.deinit();

    var result = Host.validateDocument(testing.allocator, src, .{ .preloaded = &pre }) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer result.deinit();

    // Every diagnostic — preload-borrowed context plus document-local — must
    // be structurally sound across all three phases.
    for (result.diagnostics) |d| {
        try testing.expect(d.span.end >= d.span.start);
        for (d.path) |step| try testing.expect(step.len > 0);
        _ = d.code;
        _ = d.severity;
        _ = d.phase;
    }

    // Touch the partition + loaded-plugin views; the preloaded plugins are
    // borrowed (not in `result.plugins`), so this walks only the doc-loaded
    // suffix — a corrupted slice header crashes here rather than slipping past.
    _ = result.declarations.len;
    _ = result.references.len;
    _ = result.data_forest.len;
    for (result.plugins) |p| _ = p.name.len;
}

test "fuzz Host.validateDocument (preloaded): arbitrary doc → HostResult or OOM" {
    try testing.fuzz({}, fuzzHostPreloadedValidate, .{
        .corpus = seeds(&.{
            // Bare data / atoms — no declarations, validated against preloaded.
            "",
            "nil",
            "[1 2 3]",
            // Resolves the preloaded `box` form (clean data pass).
            "(box :w 5)",
            "(box :w 5 :label \"hi\")",
            // Preloaded form, non-conforming value (data-phase diagnostic).
            "(box :w \"nope\")",
            // Preloaded form, missing required key.
            "(box)",
            // Unknown head — not covered by the preloaded schema.
            "(scene :title \"hi\")",
            // Inline plugin ADDED to the preloaded set (additive; doc-time
            // aggregate re-runs over the combined set).
            "(plugin :name p2 :version \"1.0.0\" (form :name y (key :name n :type number :optional false)))\n(y :n 1)",
            // Inline `box` collides with the preloaded `box` → ambiguous_form.
            "(plugin :name pre2 :version \"1.0.0\" (form :name box (key :name w :type number :optional false)))\n(box :w 5)",
            // use-plugin reference — unresolved with the default (null) resolver.
            "(use-plugin foo)\n(thing :x 1)",
            // Parser-recovery inputs.
            "(",
            "(box :w",
            "\"unterminated",
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 19. lsp/wasm dispatch — the one surface on this list that faces the open
//     internet. Every frame the published playground's worker hands the LSP
//     comes from a browser; `handleMessage` decodes it with no schema, and
//     each handler reads whatever `std.json.Value` shape it finds.
//
// The invariant is *not* "the request succeeded" — an unparseable frame, a
// missing `params`, an unopened uri and an unknown method are all legal and
// all answer differently (silence, an error object, `null`). What must hold
// for arbitrary bytes is that whatever DOES come back is a well-formed
// JSON-RPC response: a JSON object carrying `"jsonrpc":"2.0"` and the id it
// was asked under. That is exactly the contract `sendMethodNotFound` broke
// once by interpolating an unescaped method name (`:2368`), and the only one
// a JS client can be written against.
//
// Each iteration opens a document first, so position-taking handlers have
// real spans to walk rather than bailing on an unknown uri. The fixture
// drives the same globals `sjon_lsp_send` does and tears them down after —
// `testing.allocator` leak-checks the handler and the outbox both.
// ---------------------------------------------------------------------------

const lsp_wasm = @import("lsp/wasm.zig");

const lsp_fuzz_open =
    \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.sjon","version":1,"languageId":"sjon","text":"(phrase :name p0)\n(jump :target p0)\n(+ 1 2)"}}}
;

fn fuzzLspDispatch(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x15_9A_D1_50);

    var fx = lsp_wasm.DispatchFixture.init();
    defer fx.deinit();

    fx.send(lsp_fuzz_open);
    fx.send(buf[0..len]);

    for (fx.sent()) |msg| {
        var parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, msg, .{}) catch |err| {
            // Print before failing: the message is freed with the fixture,
            // so a bare error would lose the counterexample.
            std.debug.print("dispatcher emitted non-JSON: {s}\n", .{msg});
            return err;
        };
        defer parsed.deinit();

        try testing.expect(parsed.value == .object);
        const version = parsed.value.object.get("jsonrpc") orelse return error.ResponseMissingJsonRpc;
        try testing.expect(version == .string);
        try testing.expectEqualStrings("2.0", version.string);
        // Both emit sites are id-carrying (a result or an error); the
        // dispatcher never sends a server-initiated notification.
        _ = parsed.value.object.get("id") orelse return error.ResponseMissingId;
    }
}

test "fuzz lsp/wasm dispatch: arbitrary frames → well-formed JSON-RPC or silence" {
    try testing.fuzz({}, fuzzLspDispatch, .{
        .corpus = seeds(&.{
            // Not JSON / not an object / no method — the early-return arms.
            "",
            "null",
            "[]",
            "{}",
            "{\"jsonrpc\":\"2.0\",\"id\":1}",
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":42}",
            // Unknown method, with and without an id (only the former answers).
            \\{"jsonrpc":"2.0","id":1,"method":"textDocument/nope"}
            ,
            \\{"jsonrpc":"2.0","method":"textDocument/nope"}
            ,
            // Hostile method name — must survive JSON-string escaping.
            \\{"jsonrpc":"2.0","id":1,"method":"a\"b\nc"}
            ,
            // Lifecycle.
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
            ,
            \\{"jsonrpc":"2.0","id":1,"method":"shutdown"}
            ,
            // Position-taking requests over the pre-opened document, plus the
            // degenerate positions clients really send (negative, huge, absent).
            \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":0,"character":3}}}
            ,
            \\{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":0,"character":1}}}
            ,
            \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":1,"character":15}}}
            ,
            \\{"jsonrpc":"2.0","id":2,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":2,"character":2}}}
            ,
            \\{"jsonrpc":"2.0","id":2,"method":"textDocument/prepareRename","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":999999,"character":999999}}}
            ,
            \\{"jsonrpc":"2.0","id":2,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":0,"character":14},"newName":"p1"}}
            ,
            \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.sjon"},"position":{"line":-1,"character":-1}}}
            ,
            \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.sjon"}}}
            ,
            \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover"}
            ,
            // Whole-document requests.
            \\{"jsonrpc":"2.0","id":3,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":"file:///a.sjon"}}}
            ,
            \\{"jsonrpc":"2.0","id":3,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///a.sjon"}}}
            ,
            \\{"jsonrpc":"2.0","id":3,"method":"textDocument/foldingRange","params":{"textDocument":{"uri":"file:///a.sjon"}}}
            ,
            \\{"jsonrpc":"2.0","id":3,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///a.sjon"}}}
            ,
            \\{"jsonrpc":"2.0","id":3,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///a.sjon"}}}
            ,
            \\{"jsonrpc":"2.0","id":3,"method":"textDocument/rangeFormatting","params":{"textDocument":{"uri":"file:///a.sjon"},"range":{"start":{"line":0,"character":0},"end":{"line":9,"character":0}}}}
            ,
            \\{"jsonrpc":"2.0","id":3,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///a.sjon"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"context":{"diagnostics":[]}}}
            ,
            \\{"jsonrpc":"2.0","id":3,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"file:///a.sjon"},"range":{"start":{"line":0,"character":0},"end":{"line":9,"character":0}}}}
            ,
            \\{"jsonrpc":"2.0","id":3,"method":"textDocument/selectionRange","params":{"textDocument":{"uri":"file:///a.sjon"},"positions":[{"line":0,"character":4}]}}
            ,
            \\{"jsonrpc":"2.0","id":3,"method":"workspace/symbol","params":{"query":"p"}}
            ,
            // Document mutation — the range applier fed real and absurd ranges.
            \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.sjon","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":7}},"text":"x"}]}}
            ,
            \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.sjon","version":2},"contentChanges":[{"range":{"start":{"line":9,"character":9},"end":{"line":0,"character":0}},"text":"x"}]}}
            ,
            \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.sjon","version":2},"contentChanges":[{"text":"(zzz"}]}}
            ,
            \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///a.sjon"}}}
            ,
            // The `sjon/`-namespaced extensions, including the schema installer
            // (arbitrary manifest text straight from a playground pane).
            \\{"jsonrpc":"2.0","id":4,"method":"sjon/setSchemas","params":{"schemas":[{"uri":"inmemory://schema/0","text":"(plugin :name p :version \"1.0.0\" (form :name scene (key :name fps :type number :default 60)))"}]}}
            ,
            \\{"jsonrpc":"2.0","id":4,"method":"sjon/setSchemas","params":{"schemas":[{"uri":"inmemory://schema/0","text":"(plugin"}]}}
            ,
            \\{"jsonrpc":"2.0","id":4,"method":"sjon/setSchemas","params":{"schemas":"nope"}}
            ,
            \\{"jsonrpc":"2.0","id":4,"method":"sjon/effectiveDocument","params":{"textDocument":{"uri":"file:///a.sjon"}}}
            ,
            \\{"jsonrpc":"2.0","id":4,"method":"sjon/evalDocument","params":{"textDocument":{"uri":"file:///a.sjon"}}}
            ,
        }, .{}),
    });
}

// ---------------------------------------------------------------------------
// 20. lsp/offsets — the byte-index ↔ `Position` pair, as a property harness.
//
// Not a never-panic harness like the rest: both directions are total (no
// error set), so the thing worth pinning is that they agree. Clients send
// positions this module has to survive — a line past the end, a character
// mid-surrogate-pair, a document that isn't valid UTF-8 at all — and every
// LSP feature that slices `source[a..b]` inherits whatever these return.
//
// Three properties, chosen so each holds for ARBITRARY bytes:
//
//   * `positionToIndex` never returns an out-of-bounds index. Everything
//     downstream slices with it.
//   * Round-tripping is a fixed point: mapping an index out to a position
//     and back may move it (an index mid-codepoint has no exact position),
//     but doing it twice must land where doing it once did. Without this a
//     client could walk a cursor across a document by re-sending its own
//     reported position.
//   * On well-formed UTF-8 the round trip is *exact* at every codepoint
//     boundary, in all three encodings. This is the property a client
//     actually relies on, and the one the truncated-tail arms in the four
//     counting helpers could break asymmetrically (`countCodepoints` counts
//     a clipped trailing sequence; `codepointsToByteCount` refuses it).
//   * The reported line is the LSP line count of the prefix — all three
//     terminators, `\r\n` counted once. Restated here independently so the
//     two directions can't agree on a shared mistake.
// ---------------------------------------------------------------------------

const lsp_offsets = @import("lsp/offsets.zig");

/// Smaller than `MAX_INPUT`: the harness is O(n²) in the source length
/// (every index, times a linear scan), times three encodings.
const OFFSETS_MAX_INPUT: usize = 192;

/// Line breaks in `prefix`, which must be a prefix of `src`, counted the way
/// LSP counts them: `\n`, `\r\n`, or a lone `\r`. Needs the whole source
/// because a `\r` at the prefix boundary is only a break if what follows it
/// isn't `\n`. Spelled out longhand rather than calling the module's own
/// predicate — a harness that asks the code under test what the answer is
/// proves nothing.
fn countLineBreaks(prefix: []const u8, src: []const u8) u32 {
    var n: u32 = 0;
    for (prefix, 0..) |c, k| {
        if (c == '\n') n += 1;
        if (c == '\r' and (k + 1 >= src.len or src[k + 1] != '\n')) n += 1;
    }
    return n;
}

fn fuzzLspOffsets(_: void, smith: *Smith) anyerror!void {
    var buf: [OFFSETS_MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x0F_F5_E7_50);
    const src = buf[0..len];
    const well_formed = std.unicode.utf8ValidateSlice(src);

    for ([_]lsp_offsets.Encoding{ .@"utf-8", .@"utf-16", .@"utf-32" }) |enc| {
        for (0..src.len + 1) |i| {
            const p = lsp_offsets.indexToPosition(src, i, enc);
            try testing.expectEqual(countLineBreaks(src[0..i], src), p.line);

            const j = lsp_offsets.positionToIndex(src, p, enc);
            try testing.expect(j <= src.len);

            const j2 = lsp_offsets.positionToIndex(src, lsp_offsets.indexToPosition(src, j, enc), enc);
            try testing.expectEqual(j, j2);

            // A codepoint boundary — the only index a conforming client can
            // name — must survive the round trip untouched. The `\n` of a
            // `\r\n` is the one other unnameable index: the pair is a single
            // indivisible break, so an index between its halves is no more
            // addressable than one inside a codepoint.
            const boundary = i == src.len or (src[i] & 0xC0) != 0x80;
            const mid_crlf = i > 0 and i < src.len and src[i - 1] == '\r' and src[i] == '\n';
            if (well_formed and boundary and !mid_crlf) try testing.expectEqual(i, j);
        }

        // Indices past the end clamp rather than reading off the end.
        try testing.expectEqual(
            lsp_offsets.indexToPosition(src, src.len, enc),
            lsp_offsets.indexToPosition(src, std.math.maxInt(usize), enc),
        );

        // An arbitrary client-supplied position, including the far corners
        // of the `u32` space that a 32-bit LSP `uinteger` permits.
        const wild: lsp_offsets.Position = .{
            .line = smith.valueWithHash(u32, 0x0F_F5_E7_51),
            .character = smith.valueWithHash(u32, 0x0F_F5_E7_52),
        };
        try testing.expect(lsp_offsets.positionToIndex(src, wild, enc) <= src.len);
    }
}

test "fuzz lsp/offsets: index ↔ Position agree over arbitrary bytes" {
    try testing.fuzz({}, fuzzLspOffsets, .{
        .corpus = seeds(&.{
            "",
            "\n",
            "abc",
            "abc\ndef\nghi",
            // All three LSP terminators, including the ones that only became
            // breaks in r1-05: a lone `\r`, a mixed document, a `\r` at the
            // very end, and a `\r\r\n` where the first `\r` stands alone.
            "abc\r\ndef\r\n",
            "abc\rdef\rghi",
            "a\nb\r\nc\rd",
            "abc\r",
            "\r\r\n\r",
            "\n\r",
            // Multi-byte: 2-, 3-, and 4-byte sequences (the last one costing
            // two UTF-16 code units).
            "\xC3\xA9",
            "\xE2\x82\xAC",
            "a\xF0\x9F\x98\x80b",
            "\xF0\x9F\x98\x80\n\xF0\x9F\x98\x80",
            // Malformed: lone continuation, truncated 3- and 4-byte leads,
            // an overlong-looking lead at end of input.
            "\x80",
            "\xE2\x82",
            "\xF0\x9F\x98",
            "a\xF0",
            "\xFF\xFE",
            // Mixed valid/invalid across a line break.
            "\xE2\x82\xAC\n\xE2\x82",
        }, .{ .cap = OFFSETS_MAX_INPUT }),
    });
}

// ---------------------------------------------------------------------------
// 21. Lockfile.parse — arbitrary on-disk `sjon-project.lock` bytes.
//
// The lockfile is the one file in a project the CLI reads without the user
// having written it: `sjon project lock` generates it, git merges it, and
// `verify` / `sync` / `check` parse whatever comes back. A conflict-marker
// mash-up or a truncated write is the normal failure, not the exotic one.
// `parse` is documented to answer with `Corrupt` / `UnsupportedVersion` /
// `OutOfMemory` and nothing else, and to leave no arena behind when it does
// — `errdefer arena.deinit()` guards a function that allocates into that
// arena from ten different places.
//
// The seeds are the shapes a real lockfile degrades into: right head with
// wrong-typed values, entries missing each required key in turn, a version
// past `FORMAT_VERSION`, and the `<<<<<<<` merge conflict.
// ---------------------------------------------------------------------------

const Lockfile = sjon.Lockfile;

fn fuzzLockfile(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x10C_F11E);

    const src = try toSentinel(testing.allocator, buf[0..len]);
    defer testing.allocator.free(src);

    var lock = Lockfile.parse(testing.allocator, src) catch |err| {
        switch (err) {
            error.OutOfMemory,
            error.Corrupt,
            error.UnsupportedVersion,
            => return,
        }
    };
    defer lock.deinit();

    // A parse that succeeded must have produced a coherent table: a version
    // this build can read, and entries whose required fields are all present
    // (`find` walks `name` on every one of them).
    try testing.expect(lock.version <= Lockfile.FORMAT_VERSION);
    for (lock.plugins) |entry| {
        try testing.expect(entry.name.len > 0);
        _ = entry.version.len;
        _ = entry.path.len;
        _ = entry.manifest_hash.len;
        if (entry.wasm_hash) |h| _ = h.len;
        _ = entry.resolved_from;
        try testing.expect(lock.find(entry.name) != null);
    }
}

test "fuzz Lockfile.parse: arbitrary bytes → Lockfile or known error" {
    try testing.fuzz({}, fuzzLockfile, .{
        .corpus = seeds(&.{
            // Not a lockfile at all.
            "",
            "nil",
            "()",
            "[1 2 3]",
            "(notlockfile :version 1)",
            "(lockfile) (lockfile)",
            // Minimal well-formed.
            "(lockfile :version 1 :plugins [])\n",
            // Full well-formed, one entry, both hash shapes.
            "(lockfile :version 1\n          :project-hash \"sha256-0000000000000000000000000000000000000000000000000000000000000000\"\n          :generated-at \"2026-05-24T10:42:00Z\"\n          :sjon-version \"0.1.0\"\n          :plugins\n          [(locked :name          shapes\n                   :version       \"1.0.0\"\n                   :path          \"./vendor/shapes.sjon\"\n                   :manifest-hash \"sha256-1111111111111111111111111111111111111111111111111111111111111111\"\n                   :wasm-hash     \"sha256-2222222222222222222222222222222222222222222222222222222222222222\"\n                   :resolved-from project-plugins)])\n",
            "(lockfile :version 1 :plugins [(locked :name a :version \"1.0.0\" :path \"./a.sjon\" :manifest-hash \"sha256-3333333333333333333333333333333333333333333333333333333333333333\" :resolved-from search-roots)])\n",
            // Two entries — the sorted, multi-plugin shape.
            "(lockfile :version 1 :plugins [(locked :name a :version \"1.0.0\" :path \"./a.sjon\" :manifest-hash \"sha256-a\") (locked :name b :version \"2.0.0\" :path \"./b.sjon\" :manifest-hash \"sha256-b\")])\n",
            // Version boundaries: absent, zero, negative, past the format.
            "(lockfile :plugins [])",
            "(lockfile :version 0 :plugins [])",
            "(lockfile :version -1 :plugins [])",
            "(lockfile :version 2 :plugins [])",
            "(lockfile :version 999999999999999999999 :plugins [])",
            "(lockfile :version \"1\" :plugins [])",
            // Wrong-typed containers and members.
            "(lockfile :version 1 :plugins nil)",
            "(lockfile :version 1 :plugins [nil])",
            "(lockfile :version 1 :plugins [(notlocked :name a)])",
            "(lockfile :version 1 :plugins [(locked)])",
            // Each required entry key missing in turn.
            "(lockfile :version 1 :plugins [(locked :version \"1.0.0\" :path \"./a\" :manifest-hash \"h\")])",
            "(lockfile :version 1 :plugins [(locked :name a :path \"./a\" :manifest-hash \"h\")])",
            "(lockfile :version 1 :plugins [(locked :name a :version \"1.0.0\" :manifest-hash \"h\")])",
            "(lockfile :version 1 :plugins [(locked :name a :version \"1.0.0\" :path \"./a\")])",
            // Unknown `:resolved-from` symbol / duplicate names.
            "(lockfile :version 1 :plugins [(locked :name a :version \"1\" :path \"./a\" :manifest-hash \"h\" :resolved-from elsewhere)])",
            "(lockfile :version 1 :plugins [(locked :name a :version \"1\" :path \"./a\" :manifest-hash \"h\") (locked :name a :version \"2\" :path \"./b\" :manifest-hash \"h\")])",
            // Truncated writes and the merge conflict — the two ways a real
            // lockfile actually arrives broken.
            "(lockfile :version 1 :plugins [(locked :name a",
            "(lockfile :version 1 :plugins [(locked :name a :version \"1.0.0\" :path \"./a.sjon\" :manifest-hash \"sha256-",
            "<<<<<<< HEAD\n(lockfile :version 1 :plugins [])\n=======\n(lockfile :version 1 :plugins [(locked :name a)])\n>>>>>>> other\n",
        }, .{}),
    });
}
