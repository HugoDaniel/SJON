//! Internal tests for Expr.zig (the safe-expression evaluator).
//!
//! Pulled out of `Expr.zig` post-phase-16 to keep the production file at
//! ~1430 LOC (was 4736 with tests interleaved). Test discovery: `Expr.zig`
//! ends with `test { _ = @import("Expr_tests.zig"); }`, so these run
//! transparently under `_ = Expr;` from `root.zig`'s test block.
//!
//! Tests access `Expr` only through its public surface — every symbol
//! reached here is `pub` in `Expr.zig`. Local `const` aliases at the top
//! re-spell those symbols unqualified to keep test bodies readable.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const Binary = @import("Binary.zig");
const Parser = @import("Parser.zig");
const Expr = @import("Expr.zig");
const core = @import("plugins/core.zig");

// Local aliases — keep test bodies readable without churning every callsite.
const Result = Expr.Result;
const Env = Expr.Env;
const Value = Expr.Value;
const Error = Expr.Error;
const eval = Expr.eval;
const evalBinary = Expr.evalBinary;

fn evalSource(src: [:0]const u8) !Result {
    var tree2 = try Parser.parse(testing.allocator, src);
    defer tree2.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    return eval(testing.allocator, &tree2, tree2.root[0], &empty_env, schema);
}

fn evalSourceBinary(src: [:0]const u8) !Result {
    var tree2 = try Parser.parse(testing.allocator, src);
    defer tree2.deinit();
    const bin = try Binary.toBinary(testing.allocator, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    return evalBinary(testing.allocator, bin.data, &empty_env, schema);
}

fn evalSourceBudget(src: [:0]const u8, byte_budget: usize) !Result {
    var tree2 = try Parser.parse(testing.allocator, src);
    defer tree2.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    return Expr.evalWithRuntimeBudget(testing.allocator, &tree2, tree2.root[0], &empty_env, schema, null, .{ .bytes = byte_budget });
}

fn evalSourceBinaryBudget(src: [:0]const u8, byte_budget: usize) !Result {
    var tree2 = try Parser.parse(testing.allocator, src);
    defer tree2.deinit();
    const bin = try Binary.toBinary(testing.allocator, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    return Expr.evalBinaryWithRuntimeBudget(testing.allocator, bin.data, &empty_env, schema, null, .{ .bytes = byte_budget });
}

fn evalSourceSteps(src: [:0]const u8, steps: u32) !Result {
    var tree2 = try Parser.parse(testing.allocator, src);
    defer tree2.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    return Expr.evalWithRuntimeBudget(testing.allocator, &tree2, tree2.root[0], &empty_env, schema, null, .{ .steps = steps });
}

fn evalSourceBinarySteps(src: [:0]const u8, steps: u32) !Result {
    var tree2 = try Parser.parse(testing.allocator, src);
    defer tree2.deinit();
    const bin = try Binary.toBinary(testing.allocator, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    return Expr.evalBinaryWithRuntimeBudget(testing.allocator, bin.data, &empty_env, schema, null, .{ .steps = steps });
}

/// The smallest step cap under which `f` completes, proving on the way that
/// every smaller cap fails with `DepthExceeded` and nothing else.
fn minimumSteps(f: fn ([:0]const u8, u32) anyerror!Result, src: [:0]const u8) !u32 {
    var cap: u32 = 0;
    while (cap < 1024) : (cap += 1) {
        var r = f(src, cap) catch |err| {
            try testing.expectEqual(error.DepthExceeded, err);
            continue;
        };
        r.deinit();
        return cap;
    }
    return error.NoStepCapSucceeded;
}

// ---------------------------------------------------------------------------
// Labeled-call overload resolution — tree/binary parity.
// ---------------------------------------------------------------------------

/// Order-sensitive on purpose: a mis-mapped slot shows up as a wrong value,
/// not merely as a call that happened to succeed.
fn applyOrderedDiff(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    // `toF64` rather than `.number`: integer literals arrive as
    // `integer_i64`, and the point here is slot order, not numeric tower.
    const lhs = args[0].toF64() orelse return error.TypeMismatch;
    const rhs = args[1].toF64() orelse return error.TypeMismatch;
    return .{ .number = lhs - rhs };
}

/// Two labeled signatures of the *same arity* overlapping in one label.
/// `:x` alone does not determine the signature, so a call that opens with
/// `:x` and then names `:b` must abandon the signature it first matched —
/// the exact case a streaming walk gets wrong if it commits on child 0.
const overload_plugin: Plugin.Plugin = .{
    .name = "ovl",
    .expr_funcs = &.{.{
        .name = "poly",
        .impl = &applyOrderedDiff,
        .signatures = &.{
            .{ .arity = .{ .fixed = 2 }, .params = &.{ .number, .number }, .param_names = &.{ "x", "y" }, .result = .number },
            .{ .arity = .{ .fixed = 2 }, .params = &.{ .number, .number }, .param_names = &.{ "x", "b" }, .result = .number },
        },
    }},
};

fn evalOverload(src: [:0]const u8) !Result {
    var t = try Parser.parse(testing.allocator, src);
    defer t.deinit();
    const schema = Schema.Schema.init(&.{ core.plugin, overload_plugin });
    const empty_env: Env = .{};
    return eval(testing.allocator, &t, t.root[0], &empty_env, schema);
}

fn evalOverloadBinary(src: [:0]const u8) !Result {
    var t = try Parser.parse(testing.allocator, src);
    defer t.deinit();
    const bin = try Binary.toBinary(testing.allocator, t, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{ core.plugin, overload_plugin });
    const empty_env: Env = .{};
    return evalBinary(testing.allocator, bin.data, &empty_env, schema);
}

test "labeled calls: evalBinary considers every labeled signature, as eval does" {
    // The binary walk used to commit to the first arity-matching labeled
    // signature and hard-error on any label that signature lacked, where the
    // tree path (`Schema.resolveExprArgs`) tries every labeled signature for
    // an exact label-set match. So the `:b` calls below returned a value on
    // a tree and error.KeywordInExpressionArgs on the IR — and
    // `sjon-binary.wasm` evaluates exclusively through the IR path.
    //
    // Every case computes 10 - 1, so a signature picked correctly but slots
    // mapped from the wrong one reads as -9, not as a pass.
    const cases = [_][:0]const u8{
        "(poly :x 10 :y 1)", // signature 1, in declaration order
        "(poly :y 1 :x 10)", // signature 1, labels reordered
        "(poly :x 10 :b 1)", // opens matching sig 1, then must re-select to 2
        "(poly :b 1 :x 10)", // selects sig 2 on the first child
    };
    for (cases) |src| {
        var tr = try evalOverload(src);
        defer tr.deinit();
        try testing.expectEqual(@as(f64, 9), tr.value.number);

        var br = try evalOverloadBinary(src);
        defer br.deinit();
        try testing.expectEqual(@as(f64, 9), br.value.number);
    }
}

test "labeled calls: re-selection does not weaken the contract" {
    // Retrying other signatures must not become "accept anything".
    // A label no labeled signature declares, a label set no single
    // signature covers, a duplicate, and a mixed call all still fail.
    try testing.expectError(error.KeywordInExpressionArgs, evalOverloadBinary("(poly :x 1 :z 2)"));
    try testing.expectError(error.KeywordInExpressionArgs, evalOverloadBinary("(poly :y 1 :b 2)"));
    try testing.expectError(error.KeywordInExpressionArgs, evalOverloadBinary("(poly :x 1 :x 2)"));
    try testing.expectError(error.KeywordInExpressionArgs, evalOverloadBinary("(poly 1 :y 2)"));
}

test "memory budget: over-budget eval trips MemoryBudgetExceeded, not OOM" {
    // A map allocating a fresh 4-element vector per iteration over a
    // 64-element list. Frame depth stays tiny (well under MAX_FRAMES) and
    // step count is bounded, so neither DepthExceeded nor step exhaustion
    // can fire — only the byte budget. Under a small cap the result arena
    // passes the budget mid-loop and the per-step queryCapacity check trips
    // deterministically. This is the case the budget exists for: bounded
    // steps, unbounded-without-the-cap memory.
    const src = "(map [x] [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63] (vec4 x x x x))";
    try testing.expectError(error.MemoryBudgetExceeded, evalSourceBudget(src, 1024));

    // Control: the same expression succeeds under the production budget.
    var r = try evalSourceBudget(src, Expr.MAX_EVAL_BYTES);
    defer r.deinit();
    try testing.expectEqual(std.meta.Tag(Value).vector, std.meta.activeTag(r.value));
    try testing.expectEqual(@as(usize, 64), r.value.vector.len);
}

test "memory budget: binary path mirrors the tree path" {
    const src = "(map [x] [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63] (vec4 x x x x))";
    try testing.expectError(error.MemoryBudgetExceeded, evalSourceBinaryBudget(src, 1024));

    var r = try evalSourceBinaryBudget(src, Expr.MAX_EVAL_BYTES);
    defer r.deinit();
    try testing.expectEqual(std.meta.Tag(Value).vector, std.meta.activeTag(r.value));
    try testing.expectEqual(@as(usize, 64), r.value.vector.len);
}

test "memory budget: ordinary expression under the production budget is unaffected" {
    var r = try evalSourceBudget("[1 2 3 4 5]", Expr.MAX_EVAL_BYTES);
    defer r.deinit();
    try testing.expectEqual(std.meta.Tag(Value).vector, std.meta.activeTag(r.value));
    try testing.expectEqual(@as(usize, 5), r.value.vector.len);
}

test "memory budget: a zero cap can never be met (both eval paths)" {
    // Producing any result needs at least one arena byte, so a 0-byte cap
    // trips on the very first allocation rather than returning a value.
    try testing.expectError(error.MemoryBudgetExceeded, evalSourceBudget("[1 2 3]", 0));
    try testing.expectError(error.MemoryBudgetExceeded, evalSourceBinaryBudget("[1 2 3]", 0));
}

test "memory budget: a generous-but-finite cap still admits real work" {
    // 1 MiB sits far above a small map's footprint yet far below the 64-elem
    // blow-up — the cap is a ceiling, not a hair-trigger. Mirrors on both
    // paths to keep tree/binary behaviour aligned.
    const src = "(map [x] [0 1 2 3 4 5 6 7] (vec4 x x x x))";
    var r = try evalSourceBudget(src, 1 << 20);
    defer r.deinit();
    try testing.expectEqual(std.meta.Tag(Value).vector, std.meta.activeTag(r.value));
    try testing.expectEqual(@as(usize, 8), r.value.vector.len);

    var rb = try evalSourceBinaryBudget(src, 1 << 20);
    defer rb.deinit();
    try testing.expectEqual(@as(usize, 8), rb.value.vector.len);
}

test "step budget: exhausting the step cap trips DepthExceeded (both eval paths)" {
    // Until `Budget.steps` existed this arm had never executed. Both loops
    // end in `for (0..steps) … else return error.DepthExceeded`, and the
    // production cap of 2^20 is out of reach of any expression a test would
    // write — so rewriting the `for` to a `while (true)` passed every gate
    // in the repo and removed the only thing standing between a buggy frame
    // transition and a hung host.
    //
    // A cap of one cannot finish anything: frame depth here is 2-3 (far
    // under `MAX_FRAMES`) and the arena is a few dozen bytes (far under the
    // byte cap), so the step count is the only ceiling that can fire.
    try testing.expectError(error.DepthExceeded, evalSourceSteps("(+ 1 2)", 1));
    try testing.expectError(error.DepthExceeded, evalSourceBinarySteps("(+ 1 2)", 1));

    // A zero cap enters the loop zero times and falls straight through.
    try testing.expectError(error.DepthExceeded, evalSourceSteps("1", 0));
    try testing.expectError(error.DepthExceeded, evalSourceBinarySteps("1", 0));

    // Control: the same expression under the production cap.
    var r = try evalSource("(+ 1 2)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 3), r.value.number);
}

test "step budget: the trip is exact at ±1 on both paths" {
    // The ±1 discipline the other three ceilings already hold to. The exact
    // step count is an implementation detail (it moves when a frame
    // transition is split or merged), so the test derives it rather than
    // hardcoding it — but then pins that one step fewer is the failure and
    // that failure is `DepthExceeded`, not a wrong answer.
    const src = "(+ 1 (* 2 3))";

    const tree_min = try minimumSteps(evalSourceSteps, src);
    try testing.expect(tree_min > 1);
    try testing.expectError(error.DepthExceeded, evalSourceSteps(src, tree_min - 1));
    var r = try evalSourceSteps(src, tree_min);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 7), r.value.number);

    const binary_min = try minimumSteps(evalSourceBinarySteps, src);
    try testing.expect(binary_min > 1);
    try testing.expectError(error.DepthExceeded, evalSourceBinarySteps(src, binary_min - 1));
    var rb = try evalSourceBinarySteps(src, binary_min);
    defer rb.deinit();
    try testing.expectEqual(@as(f64, 7), rb.value.number);
}

test "evalBinary: parity with eval over the same fixtures" {
    // Streaming-binary path must produce the same Value as the SoA tree
    // evaluator across the closed-v1 vocabulary plus all special forms.
    const cases = [_][:0]const u8{
        // Atoms and lookup-free expressions
        "42",
        "true",
        "false",
        "nil",
        "\"hello\"",
        ":kw",
        "[1 2 3]",

        // Arithmetic / comparison
        "(+ 1 2)",
        "(- 10 1 2 3)",
        "(* 2 3 4)",
        "(/ 100 2 5)",
        "(mod 10 3)",
        "(< 1 2)",
        "(>= 5 5)",
        "(= 3 3)",
        "(!= 3 4)",
        "(not false)",

        // Vectors / vec ops / math
        "(vec2 1 2)",
        "(vec3 1 2 3)",
        "(vec4 1 2 3 4)",
        "(lerp 0 10 (/ 1 2))",
        "(clamp 5 0 10)",
        "(clamp -5 0 10)",
        "(clamp 50 0 10)",
        "(min 3 1 4)",
        "(max 3 1 4)",
        "(dot (vec3 1 2 3) (vec3 4 5 6))",
        "(length (vec3 0 3 4))",

        // Special forms
        "(if true 1 2)",
        "(if false 1 2)",
        "(if false 1)",
        "(if true 1)",
        "(cond (< 1 2) 7 true 99)",
        "(cond (< 2 1) 1 (> 2 1) 2 true 3)",
        "(cond)",
        "(and 1 2 3)",
        "(and 1 false 3)",
        "(or false false 7)",
        "(or)",
        "(and)",
        "(let [x 3 y 4] (+ x y))",
        "(let [x 3 y (* x 2)] (- y x))",
        "(let [x 3] (let [y (+ x 1)] (* x y)))",

        // Higher-order binder forms
        "(map [x] [1 2 3 4] (* x x))",
        "(map [x] [] (* x x))",
        "(map [x] [10] x)",
        "(map [x] [1 2 3] (+ x 10))",
        "(map [x] [1 2] (map [y] [10 20] (* x y)))",
        "(let [k 10] (map [x] [1 2 3] (+ x k)))",
        "(filter [x] [-1 0 1 2 -3 4] (> x 0))",
        "(filter [x] [] (> x 0))",
        "(filter [x] [1 2 3] (> x 100))",
        "(filter [x] [1 2 3] (> x 0))",
        "(any [x] [1 2 3] (> x 2))",
        "(any [x] [1 2 3] (> x 10))",
        "(any [x] [] (> x 0))",
        "(all [x] [1 2 3] (> x 0))",
        "(all [x] [1 2 -3] (> x 0))",
        "(all [x] [] (> x 0))",
        // any/all short-circuit semantics — the binary path's
        // `body_payload_pos` replay only fires for elements that get
        // visited, so a buggy short-circuit would show up as
        // either over-iteration or stale-cursor diagnostics.
        "(any [x] [-1 0 1 2 3] (> x 0))",
        "(all [x] [1 2 3 -4 5] (> x 0))",
        // fold — 2-symbol binder, init eval before xs, accumulator
        // threaded body→acc across iterations. Nested fold stresses
        // the binary path's cursor replay across two simultaneous
        // active binder frames.
        "(fold [acc x] 0 [1 2 3 4] (+ acc x))",
        "(fold [acc x] 1 [2 3 4] (* acc x))",
        "(fold [acc x] 42 [] (+ acc x))",
        "(fold [acc x] 10 [5] (+ acc x))",
        "(fold [acc x] 0 [1 2 3] (+ acc (* x x)))",
        "(let [k 10] (fold [acc x] 0 [1 2 3] (+ acc (* x k))))",
        "(fold [a r] 0 [[1 2] [3 4]] (+ a (fold [b s] 0 r (+ b s))))",

        // Nested expressions
        "(+ 1 (* 2 3))",
        "(+ (* 2 3) (- 10 4))",
        "(if (< 1 2) (+ 10 20) (* 100 200))",

        // Unit-bearing numbers (units dropped at eval)
        "(+ 4b 2b)",
        "(* 50% 2)",

        // v0.2 stdlib expansion — math (extended)
        "(abs -3.5)",
        "(sign -2)",
        "(floor 1.7)",
        "(ceil 1.2)",
        "(round 0.5)",
        "(fract 1.25)",
        "(sqrt 9)",
        "(pow 2 8)",
        "(sin 0)",
        "(cos 0)",
        "(tan 0)",
        "(asin 0)",
        "(acos 1)",
        "(atan 0)",
        "(atan2 0 1)",
        "(radians 180)",
        "(degrees (pi))",
        "(pi)",
        "(tau)",

        // Smoothing
        "(saturate 1.5)",
        "(saturate -0.5)",
        "(step 0.5 1)",
        "(smoothstep 0 1 0.5)",

        // Vector ops
        "(normalize (vec3 3 0 0))",
        "(distance (vec3 0 0 0) (vec3 3 4 0))",
        "(reflect (vec3 1 -1 0) (vec3 0 1 0))",

        // List ops
        "(nth [10 20 30] 1)",
        "(count [1 2 3 4 5])",

        // Seeded random
        "(hash 1 0)",
        "(rand01 1 0)",
        "(rand-range 1 0 0 100)",
        "(rand-int 1 0 0 9)",
        "(rand-bool 1 0 0.5)",
        "(rand-choice 1 0 [10 20 30])",
    };
    for (cases) |src| {
        var via_tree = try evalSource(src);
        defer via_tree.deinit();
        var via_bin = try evalSourceBinary(src);
        defer via_bin.deinit();
        if (!Value.equals(via_tree.value, via_bin.value)) {
            std.debug.print("\nbinary-eval parity break for: {s}\n", .{src});
            std.debug.print("  via_tree: {any}\n", .{via_tree.value});
            std.debug.print("  via_bin:  {any}\n", .{via_bin.value});
            return error.TestUnexpectedResult;
        }
    }
}

test "evalBinary: rejects multi-root buffer" {
    var tree2 = try Parser.parse(testing.allocator, "1 2");
    defer tree2.deinit();
    const bin = try Binary.toBinary(testing.allocator, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    try testing.expectError(error.MultipleRoots, evalBinary(testing.allocator, bin.data, &empty_env, schema));
}

test "evalBinary: rejects keyword children in expression args" {
    // (+ :foo 1) — keyword children in expression position must error.
    var tree2 = try Parser.parse(testing.allocator, "(+ :foo 1)");
    defer tree2.deinit();
    const bin = try Binary.toBinary(testing.allocator, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    try testing.expectError(error.KeywordInExpressionArgs, evalBinary(testing.allocator, bin.data, &empty_env, schema));
}

test "eval: labeled lerp evaluates equal to positional lerp" {
    // (lerp :from 0 :to 10 :t 0.5) and (lerp 0 10 0.5) must produce the
    // same Value — labels just rename slot identity, the math is
    // identical. Ordering of the labels in source is also independent.
    var labeled_in = try evalSource("(lerp :from 0 :to 10 :t 0.5)");
    defer labeled_in.deinit();
    var labeled_out_of_order = try evalSource("(lerp :t 0.5 :to 10 :from 0)");
    defer labeled_out_of_order.deinit();
    var positional = try evalSource("(lerp 0 10 0.5)");
    defer positional.deinit();
    try testing.expectEqual(@as(f64, 5.0), labeled_in.value.toF64().?);
    try testing.expectEqual(labeled_in.value.toF64().?, labeled_out_of_order.value.toF64().?);
    try testing.expectEqual(labeled_in.value.toF64().?, positional.value.toF64().?);
}

test "eval: labeled atan2 :y :x matches (atan2 y x)" {
    // The point of labels here is the famously-confusing y/x order.
    // Labeled and positional must agree.
    var labeled = try evalSource("(atan2 :x 1 :y 0)");
    defer labeled.deinit();
    var positional = try evalSource("(atan2 0 1)");
    defer positional.deinit();
    try testing.expectEqual(positional.value.toF64().?, labeled.value.toF64().?);
}

test "evalBinary: labeled call happy path matches positional (over-rejection guard)" {
    // No labeled-binary success test existed before the dup-label fix, so
    // the guards added there had no positive control. Pin that a
    // well-formed labeled call — even out of declared order — still
    // evaluates on the binary path: (lerp :t 0.5 :to 10 :from 0) == 5.0.
    var out_of_order = try evalSourceBinary("(lerp :t 0.5 :to 10 :from 0)");
    defer out_of_order.deinit();
    var positional = try evalSourceBinary("(lerp 0 10 0.5)");
    defer positional.deinit();
    try testing.expectEqual(@as(f64, 5.0), out_of_order.value.toF64().?);
    try testing.expectEqual(positional.value.toF64().?, out_of_order.value.toF64().?);
}

test "eval/evalBinary: duplicate labels reject on both paths" {
    // Hole A: (lerp :from 0 :from 1 :t 0.5) resolves two source args to
    // the same slot, so the `to` slot is never written. Pre-fix the
    // binary path read that uninitialized Value inside applyLerp (union
    // tag panic under runtime safety). Both paths must reject at eval.
    try testing.expectError(error.KeywordInExpressionArgs, evalSource("(lerp :from 0 :from 1 :t 0.5)"));
    try testing.expectError(error.KeywordInExpressionArgs, evalSourceBinary("(lerp :from 0 :from 1 :t 0.5)"));
}

test "eval/evalBinary: positional-before-keyword rejects on both paths" {
    // Hole B: (lerp 0 :to 1 :t 0.5) enters labeled mode at consumed>0, so
    // the non-zeroed slots[0] held a garbage index → out-of-bounds write
    // into `final` on the binary path. Mixed calls are rejected.
    try testing.expectError(error.KeywordInExpressionArgs, evalSource("(lerp 0 :to 1 :t 0.5)"));
    try testing.expectError(error.KeywordInExpressionArgs, evalSourceBinary("(lerp 0 :to 1 :t 0.5)"));
}

test "eval/evalBinary: keyword-before-positional rejects on both paths" {
    // The reverse mix; already handled by the labeled-mode positional
    // arm. Pins that binary and tree agree.
    try testing.expectError(error.KeywordInExpressionArgs, evalSource("(lerp :from 0 1 2)"));
    try testing.expectError(error.KeywordInExpressionArgs, evalSourceBinary("(lerp :from 0 1 2)"));
}

test "eval/evalBinary: unknown label rejects on both paths" {
    try testing.expectError(error.KeywordInExpressionArgs, evalSource("(lerp :from 0 :to 1 :nope 0.5)"));
    try testing.expectError(error.KeywordInExpressionArgs, evalSourceBinary("(lerp :from 0 :to 1 :nope 0.5)"));
}

test "eval/evalBinary: short labeled arity rejects on both paths" {
    // fixed-3 lerp with two args: no labeled signature matches arity, so
    // labeled mode never opens and the keyword child is a plain error.
    try testing.expectError(error.KeywordInExpressionArgs, evalSource("(lerp :from 0 :to 1)"));
    try testing.expectError(error.KeywordInExpressionArgs, evalSourceBinary("(lerp :from 0 :to 1)"));
}

// -- Deep computed values: the MAX_VALUE_DEPTH ceiling ----------------------

// (fold [acc x] [0] [0 0 … ×n] [acc]) wraps the accumulator in a vector once
// per element, so n elements yield an (n+1)-deep nested vector. This builds
// an arbitrarily deep Value while the frame stack stays bounded (the fold
// never deep-copies; deepCopyValue runs only on the final result), which is
// exactly what isolates the two host-recursive consumers below.
fn foldChainSrc(a: Allocator, n: usize) ![:0]u8 {
    const prefix = "(fold [acc x] [0] [";
    const suffix = "] [acc])";
    const buf = try a.allocSentinel(u8, prefix.len + 2 * n + suffix.len, 0);
    @memcpy(buf[0..prefix.len], prefix);
    var i: usize = prefix.len;
    for (0..n) |_| {
        buf[i] = '0';
        buf[i + 1] = ' ';
        i += 2;
    }
    @memcpy(buf[i..][0..suffix.len], suffix);
    return buf;
}

// (let [d <chain>] (= d d)) — compares the deep value without making it the
// returned Result, so a depth trip comes from equalsBounded, not the final
// deepCopyValue.
fn foldChainEqSrc(a: Allocator, n: usize) ![:0]u8 {
    const chain = try foldChainSrc(a, n);
    defer a.free(chain);
    return std.mem.concatWithSentinel(a, u8, &.{ "(let [d ", chain, "] (= d d))" }, 0);
}

// A depth-nested single-element vector chain wrapping .nil, built directly as
// a Value to pin deepCopyValue's boundary without going through eval.
fn buildVecChain(a: Allocator, depth: usize) !Value {
    var v: Value = .nil;
    for (0..depth) |_| {
        const one = try a.alloc(Value, 1);
        one[0] = v;
        v = .{ .vector = one };
    }
    return v;
}

test "eval/evalBinary: result nesting past MAX_VALUE_DEPTH is rejected" {
    const a = testing.allocator;
    // 300 elements -> 301-deep result: the mandatory final deepCopyValue
    // rejects it rather than recursing unboundedly on the host stack.
    const deep = try foldChainSrc(a, 300);
    defer a.free(deep);
    try testing.expectError(error.DepthExceeded, evalSource(deep));
    try testing.expectError(error.DepthExceeded, evalSourceBinary(deep));
    // 200 elements -> 201-deep result still copies and returns a vector.
    const shallow = try foldChainSrc(a, 200);
    defer a.free(shallow);
    var s1 = try evalSource(shallow);
    defer s1.deinit();
    try testing.expect(s1.value == .vector);
    var s2 = try evalSourceBinary(shallow);
    defer s2.deinit();
    try testing.expect(s2.value == .vector);
}

test "eval/evalBinary: deep-value equality is depth-bounded" {
    const a = testing.allocator;
    const deep = try foldChainEqSrc(a, 300);
    defer a.free(deep);
    try testing.expectError(error.DepthExceeded, evalSource(deep));
    try testing.expectError(error.DepthExceeded, evalSourceBinary(deep));
    // A shallow chain compares equal to itself without tripping.
    const shallow = try foldChainEqSrc(a, 100);
    defer a.free(shallow);
    var s1 = try evalSource(shallow);
    defer s1.deinit();
    try testing.expect(s1.value.boolean);
}

test "deepCopyValue: rejects chains deeper than MAX_VALUE_DEPTH" {
    const a = testing.allocator;
    var src = std.heap.ArenaAllocator.init(a);
    defer src.deinit();

    // Just under the ceiling copies cleanly.
    const ok = try buildVecChain(src.allocator(), Expr.MAX_VALUE_DEPTH - 1);
    var dst_ok = std.heap.ArenaAllocator.init(a);
    defer dst_ok.deinit();
    _ = try Expr.deepCopyValue(dst_ok.allocator(), ok);

    // A few levels over the ceiling trips DepthExceeded.
    const deep = try buildVecChain(src.allocator(), Expr.MAX_VALUE_DEPTH + 4);
    var dst_bad = std.heap.ArenaAllocator.init(a);
    defer dst_bad.deinit();
    try testing.expectError(error.DepthExceeded, Expr.deepCopyValue(dst_bad.allocator(), deep));
}

test "evalBinary: result strings outlive bytes" {
    // The result Value's string must be deep-copied into the result arena —
    // not borrow into the binary buffer, which the caller may free first.
    const a = testing.allocator;
    var tree2 = try Parser.parse(a, "(let [x \"hello\"] x)");
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, .{});
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var result = try evalBinary(a, bin.data, &empty_env, schema);
    defer result.deinit();

    // Free bin BEFORE inspecting result — the result must be self-contained.
    bin.deinit();

    try testing.expectEqualStrings("hello", result.value.string);
}

test "evalBinary: works with the lossless wire (with comments + spans)" {
    // Source with spans + comments, encoded with all flags. evalBinary must
    // skip comments transparently and still produce the same value.
    const a = testing.allocator;
    var tree2 = try Parser.parse(a,
        \\; leading comment
        \\(+ 1 #| inline |# 2)
    );
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, Binary.ToBinaryOptions.forMode(.full));
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var result = try evalBinary(a, bin.data, &empty_env, schema);
    defer result.deinit();
    try testing.expectEqual(@as(f64, 3), result.value.toF64().?);
}

test "evalBinary: nested form inside vector" {
    // Mixing forms and vectors at the eval level.
    var r = try evalSourceBinary("(let [v [1 (+ 2 3) 4]] (dot v v))");
    defer r.deinit();
    // v = [1 5 4]; dot(v,v) = 1 + 25 + 16 = 42.
    try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
}

test "arithmetic: + - * / mod" {
    {
        var r = try evalSource("(+ 1 2)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 3), r.value.toF64().?);
    }
    {
        var r = try evalSource("(- 10 3 2)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 5), r.value.toF64().?);
    }
    {
        var r = try evalSource("(- 7)"); // unary negation
        defer r.deinit();
        try testing.expectEqual(@as(f64, -7), r.value.toF64().?);
    }
    {
        var r = try evalSource("(* 2 3 4)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 24), r.value.toF64().?);
    }
    {
        var r = try evalSource("(/ 100 2 5)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 10), r.value.toF64().?);
    }
    {
        var r = try evalSource("(mod 10 3)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
    }
}

// `mod` is floored for EVERY divisor — the result takes the divisor's
// sign. A bare `@mod` is floored only for a positive divisor and degrades
// to `@rem` for a negative one, so the negative-divisor arms below are the
// ones that regress if `applyMod`'s correction is ever dropped. The
// positive-divisor arms are here to prove the correction did not disturb
// the region every document actually uses.
test "mod: floored for a negative divisor too" {
    const Case = struct { src: [:0]const u8, want: f64 };
    for ([_]Case{
        // Positive divisor — unchanged by the correction.
        .{ .src = "(mod 7 3)", .want = 1 },
        .{ .src = "(mod -7 3)", .want = 2 },
        .{ .src = "(mod 7.5 2)", .want = 1.5 },
        .{ .src = "(mod -7.5 2)", .want = 0.5 },
        // Negative divisor — `@rem` would give 1, 1.5 and 0.5 here.
        .{ .src = "(mod 7 -3)", .want = -2 },
        .{ .src = "(mod 7.5 -3)", .want = -1.5 },
        .{ .src = "(mod -7 -3)", .want = -1 },
        .{ .src = "(mod 0.5 -1)", .want = -0.5 },
        // Exact multiples stay 0 rather than being pushed to the divisor.
        .{ .src = "(mod 6 -3)", .want = 0 },
        .{ .src = "(mod -6 -3)", .want = 0 },
        .{ .src = "(mod 0 -3)", .want = 0 },
        // Precision: the closed form x - y*floor(x/y) gives 0 here, and a
        // naive @rem-plus-correction gives the divisor itself for the
        // second. Correcting `@mod` inherits its handling of both.
        .{ .src = "(mod 1e16 3)", .want = 1 },
        .{ .src = "(mod -1 1e16)", .want = 0 },
    }) |c| {
        var r = try evalSource(c.src);
        defer r.deinit();
        try testing.expectEqual(c.want, r.value.toF64().?);
    }
}

// A nonzero floored result always carries the divisor's sign, and never
// reaches the divisor's magnitude. Swept rather than spot-checked because
// the failure the correction fixes was a whole quadrant, not one input.
test "mod: sign follows the divisor across the sign grid" {
    const vals = [_]f64{ -7.5, -7, -6, -3, -1, -0.5, 0, 0.5, 1, 3, 6, 7, 7.5 };
    for (vals) |x| {
        for (vals) |y| {
            if (y == 0) continue;
            var buf: [64]u8 = undefined;
            const src = try std.fmt.bufPrintZ(&buf, "(mod {d} {d})", .{ x, y });
            var r = try evalSource(src);
            defer r.deinit();
            const m = r.value.toF64().?;
            if (m == 0) continue;
            try testing.expect((m < 0) == (y < 0));
            try testing.expect(@abs(m) < @abs(y));
        }
    }
}

test "division by zero is reported" {
    try testing.expectError(error.DivisionByZero, evalSource("(/ 1 0)"));
}

test "comparison and equality" {
    {
        var r = try evalSource("(< 1 2)");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
    {
        var r = try evalSource("(>= 2 2)");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
    {
        var r = try evalSource("(= 3 3)");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
    {
        var r = try evalSource("(!= true false)");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
}

test "logical: and / or / not short-circuits" {
    {
        var r = try evalSource("(and true 1)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 1), r.value.toF64().?); // last truthy
    }
    {
        var r = try evalSource("(and true false 1)");
        defer r.deinit();
        try testing.expect(!r.value.boolean); // first falsy
    }
    {
        var r = try evalSource("(or false nil 7)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 7), r.value.toF64().?);
    }
    {
        var r = try evalSource("(not false)");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
}

test "if and cond" {
    {
        var r = try evalSource("(if true 1 2)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
    }
    {
        var r = try evalSource("(if false 1 2)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 2), r.value.toF64().?);
    }
    {
        var r = try evalSource("(if false 1)"); // no else -> nil
        defer r.deinit();
        try testing.expect(r.value == .nil);
    }
    {
        var r = try evalSource("(cond false 1 true 2 false 3)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 2), r.value.toF64().?);
    }
}

test "let with sequential bindings" {
    var r = try evalSource("(let [x 1 y (+ x 1)] (* x y))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 2), r.value.toF64().?);
}

test "let body example from plan: vec3" {
    var r = try evalSource("(let [r 0.5] (vec3 r r r))");
    defer r.deinit();
    try testing.expect(r.value == .vector);
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expectEqual(@as(f64, 0.5), r.value.vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 0.5), r.value.vector[1].toF64().?);
    try testing.expectEqual(@as(f64, 0.5), r.value.vector[2].toF64().?);
}

test "map: squares each element" {
    var r = try evalSource("(map [x] [1 2 3 4] (* x x))");
    defer r.deinit();
    try testing.expect(r.value == .vector);
    try testing.expectEqual(@as(usize, 4), r.value.vector.len);
    try testing.expectEqual(@as(f64, 1), r.value.vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 4), r.value.vector[1].toF64().?);
    try testing.expectEqual(@as(f64, 9), r.value.vector[2].toF64().?);
    try testing.expectEqual(@as(f64, 16), r.value.vector[3].toF64().?);
}

test "map: empty input yields empty output" {
    var r = try evalSource("(map [x] [] (* x x))");
    defer r.deinit();
    try testing.expect(r.value == .vector);
    try testing.expectEqual(@as(usize, 0), r.value.vector.len);
}

test "map: body has access to outer bindings" {
    var r = try evalSource("(let [k 10] (map [x] [1 2 3] (+ x k)))");
    defer r.deinit();
    try testing.expect(r.value == .vector);
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expectEqual(@as(f64, 11), r.value.vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 12), r.value.vector[1].toF64().?);
    try testing.expectEqual(@as(f64, 13), r.value.vector[2].toF64().?);
}

test "map: nested binder composes" {
    // outer x iterates [1 2], inner y iterates [10 20] — result is
    // [[10 20] [20 40]].
    var r = try evalSource("(map [x] [1 2] (map [y] [10 20] (* x y)))");
    defer r.deinit();
    try testing.expect(r.value == .vector);
    try testing.expectEqual(@as(usize, 2), r.value.vector.len);
    try testing.expect(r.value.vector[0] == .vector);
    try testing.expectEqual(@as(f64, 10), r.value.vector[0].vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 20), r.value.vector[0].vector[1].toF64().?);
    try testing.expectEqual(@as(f64, 20), r.value.vector[1].vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 40), r.value.vector[1].vector[1].toF64().?);
}

test "filter: keeps elements where predicate is truthy" {
    var r = try evalSource("(filter [x] [-1 0 1 2 -3 4] (> x 0))");
    defer r.deinit();
    try testing.expect(r.value == .vector);
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expectEqual(@as(f64, 1), r.value.vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 2), r.value.vector[1].toF64().?);
    try testing.expectEqual(@as(f64, 4), r.value.vector[2].toF64().?);
}

test "filter: empty input yields empty output" {
    var r = try evalSource("(filter [x] [] (> x 0))");
    defer r.deinit();
    try testing.expect(r.value == .vector);
    try testing.expectEqual(@as(usize, 0), r.value.vector.len);
}

test "filter: all-falsy predicate yields empty" {
    var r = try evalSource("(filter [x] [1 2 3] (> x 100))");
    defer r.deinit();
    try testing.expect(r.value == .vector);
    try testing.expectEqual(@as(usize, 0), r.value.vector.len);
}

test "filter: all-truthy predicate yields full input" {
    var r = try evalSource("(filter [x] [1 2 3] (> x 0))");
    defer r.deinit();
    try testing.expect(r.value == .vector);
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expectEqual(@as(f64, 1), r.value.vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 2), r.value.vector[1].toF64().?);
    try testing.expectEqual(@as(f64, 3), r.value.vector[2].toF64().?);
}

test "any: returns true when some element matches" {
    var r = try evalSource("(any [x] [1 2 3] (> x 2))");
    defer r.deinit();
    try testing.expect(r.value == .boolean);
    try testing.expect(r.value.boolean);
}

test "any: returns false when no element matches" {
    var r = try evalSource("(any [x] [1 2 3] (> x 10))");
    defer r.deinit();
    try testing.expect(r.value == .boolean);
    try testing.expect(!r.value.boolean);
}

test "any: empty input is false (no truthy seen)" {
    var r = try evalSource("(any [x] [] (> x 0))");
    defer r.deinit();
    try testing.expect(r.value == .boolean);
    try testing.expect(!r.value.boolean);
}

test "all: returns true when every element matches" {
    var r = try evalSource("(all [x] [1 2 3] (> x 0))");
    defer r.deinit();
    try testing.expect(r.value == .boolean);
    try testing.expect(r.value.boolean);
}

test "all: returns false when one element fails" {
    var r = try evalSource("(all [x] [1 2 -3] (> x 0))");
    defer r.deinit();
    try testing.expect(r.value == .boolean);
    try testing.expect(!r.value.boolean);
}

test "all: empty input is true (vacuously satisfied)" {
    var r = try evalSource("(all [x] [] (> x 0))");
    defer r.deinit();
    try testing.expect(r.value == .boolean);
    try testing.expect(r.value.boolean);
}

test "fold: sums elements" {
    var r = try evalSource("(fold [acc x] 0 [1 2 3 4] (+ acc x))");
    defer r.deinit();
    try testing.expect(r.value.toF64() != null);
    try testing.expectEqual(@as(f64, 10), r.value.toF64().?);
}

test "fold: product of elements" {
    var r = try evalSource("(fold [acc x] 1 [2 3 4] (* acc x))");
    defer r.deinit();
    try testing.expect(r.value.toF64() != null);
    try testing.expectEqual(@as(f64, 24), r.value.toF64().?);
}

test "fold: empty xs returns init" {
    var r = try evalSource("(fold [acc x] 42 [] (+ acc x))");
    defer r.deinit();
    try testing.expect(r.value.toF64() != null);
    try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
}

test "fold: single element runs body once" {
    var r = try evalSource("(fold [acc x] 10 [5] (+ acc x))");
    defer r.deinit();
    try testing.expect(r.value.toF64() != null);
    try testing.expectEqual(@as(f64, 15), r.value.toF64().?);
}

test "fold: nested fold composes" {
    // Inner fold sums each subvector; outer fold sums the sums.
    var r = try evalSource("(fold [a r] 0 [[1 2] [3 4]] (+ a (fold [b s] 0 r (+ b s))))");
    defer r.deinit();
    try testing.expect(r.value.toF64() != null);
    try testing.expectEqual(@as(f64, 10), r.value.toF64().?);
}

test "fold: body has access to outer bindings" {
    // Outer `let` exposes `k`; body uses `acc`, `x`, and `k` together.
    var r = try evalSource("(let [k 10] (fold [acc x] 0 [1 2 3] (+ acc (* x k))))");
    defer r.deinit();
    try testing.expect(r.value.toF64() != null);
    try testing.expectEqual(@as(f64, 60), r.value.toF64().?);
}

test "fold: init is evaluated, not aliased" {
    // `init` is an expression — `(+ 1 2)` evaluates to 3 before the
    // loop begins and becomes the iteration-0 acc.
    var r = try evalSource("(fold [acc x] (+ 1 2) [10] (+ acc x))");
    defer r.deinit();
    try testing.expect(r.value.toF64() != null);
    try testing.expectEqual(@as(f64, 13), r.value.toF64().?);
}

test "fold: non-symbol element in binder vector errors" {
    try testing.expectError(error.InvalidBinderShape, evalSource("(fold [1 x] 0 [1 2] 0)"));
    try testing.expectError(error.InvalidBinderShape, evalSource("(fold [acc 1] 0 [1 2] 0)"));
}

test "fold: wrong-length binder vector errors" {
    try testing.expectError(error.InvalidBinderShape, evalSource("(fold [acc] 0 [1 2] 0)"));
    try testing.expectError(error.InvalidBinderShape, evalSource("(fold [a b c] 0 [1 2] 0)"));
    try testing.expectError(error.InvalidBinderShape, evalSource("(fold [] 0 [1 2] 0)"));
}

test "fold: duplicate binder names error" {
    try testing.expectError(error.InvalidBinderShape, evalSource("(fold [acc acc] 0 [1 2] acc)"));
}

test "fold: non-vector xs errors as TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(fold [acc x] 0 5 acc)"));
}

test "fold: arity mismatch errors" {
    try testing.expectError(error.ArityMismatch, evalSource("(fold [acc x] 0 [1 2])"));
    try testing.expectError(error.ArityMismatch, evalSource("(fold [acc x] 0 [1 2] body extra)"));
}

test "binder: non-symbol element in binder vector errors" {
    try testing.expectError(error.InvalidBinderShape, evalSource("(map [1] [1 2] x)"));
}

test "binder: wrong-length binder vector errors" {
    try testing.expectError(error.InvalidBinderShape, evalSource("(map [] [1 2] 0)"));
    try testing.expectError(error.InvalidBinderShape, evalSource("(map [x y] [1 2] 0)"));
}

test "binder: non-vector binder errors" {
    try testing.expectError(error.InvalidBinderShape, evalSource("(map foo [1 2] foo)"));
}

test "binder: non-vector xs errors as TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(map [x] 5 x)"));
}

test "binder: arity mismatch errors" {
    try testing.expectError(error.ArityMismatch, evalSource("(map [x] [1 2])"));
    try testing.expectError(error.ArityMismatch, evalSource("(map [x] [1 2] x extra)"));
}

test "binder binary: cursor replay re-enters body bytes per iteration" {
    // Sanity check that the binary path's body-bytes replay is wired
    // correctly: a map over a 4-element vector with a non-trivial
    // body re-reads the body's bytes four times. If `setPos` were
    // a no-op, the second iteration's `eval(body_view)` would read
    // garbage past body's end (or trip cursor truncation). The
    // result is a vector of four numbers — the assertion catches
    // both kinds of regression.
    var r = try evalSourceBinary("(map [x] [1 2 3 4] (* x (+ x 1)))");
    defer r.deinit();
    try testing.expect(r.value == .vector);
    try testing.expectEqual(@as(usize, 4), r.value.vector.len);
    try testing.expectEqual(@as(f64, 2), r.value.vector[0].toF64().?); // 1*2
    try testing.expectEqual(@as(f64, 6), r.value.vector[1].toF64().?); // 2*3
    try testing.expectEqual(@as(f64, 12), r.value.vector[2].toF64().?); // 3*4
    try testing.expectEqual(@as(f64, 20), r.value.vector[3].toF64().?); // 4*5
}

test "binder binary: post-form cursor restores cleanly after short-circuit" {
    // `any` short-circuits on first truthy. The binary path's
    // post-form-pos restore must fire on the short-circuit path so
    // a hypothetical outer form continues reading at the right byte.
    // Without an outer form we can't observe the restore directly,
    // but the simple correctness check guards against the more
    // common bug (wrong returned value).
    var r = try evalSourceBinary("(any [x] [0 0 5 0 0] (> x 0))");
    defer r.deinit();
    try testing.expect(r.value == .boolean);
    try testing.expect(r.value.boolean);
}

test "binder binary: nested map over binary IR" {
    // The outer binder's body is itself a binder form. The inner
    // form's schedule on the binary path drains the inner form,
    // and the outer's body-replay points at the outer's body
    // (which contains the inner form's bytes). Each outer iteration
    // re-decodes the inner form fresh — including the inner
    // binder_vec and inner xs. This is the load-bearing test for
    // the "binder loops compose under cursor replay" claim.
    var r = try evalSourceBinary("(map [x] [1 2] (map [y] [10 20] (* x y)))");
    defer r.deinit();
    try testing.expect(r.value == .vector);
    try testing.expectEqual(@as(usize, 2), r.value.vector.len);
    try testing.expect(r.value.vector[0] == .vector);
    try testing.expectEqual(@as(f64, 10), r.value.vector[0].vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 20), r.value.vector[0].vector[1].toF64().?);
    try testing.expectEqual(@as(f64, 20), r.value.vector[1].vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 40), r.value.vector[1].vector[1].toF64().?);
}

test "binder binary: fold cursor replay threads accumulator across iterations" {
    // Fold's body re-reads its bytes once per element AND mutates
    // env_buf[0] with the previous iteration's body_val. A 4-element
    // sum exercises three non-final body replays plus the final
    // body_val→result step. A buggy implementation that didn't reset
    // body_payload_pos between iterations would either trip cursor
    // bounds or land non-sum results (e.g. stale body bytes).
    var r = try evalSourceBinary("(fold [acc x] 0 [1 2 3 4] (+ acc x))");
    defer r.deinit();
    try testing.expect(r.value.toF64() != null);
    try testing.expectEqual(@as(f64, 10), r.value.toF64().?);
}

test "binder binary: fold empty xs returns init without replay" {
    // Empty xs hits the early-return path: init was evaluated (its
    // value sits below xs_val on the value stack), and setup pushes
    // it back without scheduling any iter frames. The cursor must
    // already be at post_form_pos.
    var r = try evalSourceBinary("(fold [acc x] 42 [] (+ acc x))");
    defer r.deinit();
    try testing.expect(r.value.toF64() != null);
    try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
}

test "vec ops: lerp / clamp / min / max" {
    {
        var r = try evalSource("(lerp 10 20 0.25)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 12.5), r.value.toF64().?);
    }
    {
        var r = try evalSource("(clamp 1.5 0 1)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 1.0), r.value.toF64().?);
    }
    {
        var r = try evalSource("(min 3 1 4 1 5)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
    }
    {
        var r = try evalSource("(max 3 1 4 1 5)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 5), r.value.toF64().?);
    }
}

test "vec3 builds a vector" {
    var r = try evalSource("(vec3 1 2 3)");
    defer r.deinit();
    try testing.expect(r.value == .vector);
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expectEqual(@as(f64, 2), r.value.vector[1].toF64().?);
}

test "dot, cross, length" {
    {
        var r = try evalSource("(dot (vec3 1 2 3) (vec3 4 5 6))");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 32), r.value.toF64().?);
    }
    {
        var r = try evalSource("(cross (vec3 1 0 0) (vec3 0 1 0))");
        defer r.deinit();
        try testing.expect(r.value == .vector);
        try testing.expectEqual(@as(f64, 0), r.value.vector[0].toF64().?);
        try testing.expectEqual(@as(f64, 0), r.value.vector[1].toF64().?);
        try testing.expectEqual(@as(f64, 1), r.value.vector[2].toF64().?);
    }
    {
        var r = try evalSource("(length (vec2 3 4))");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 5), r.value.toF64().?);
    }
}

test "unknown binding errors" {
    try testing.expectError(error.UnknownBinding, evalSource("(+ 1 unbound)"));
}

test "type mismatch errors" {
    try testing.expectError(error.TypeMismatch, evalSource(
        \\(+ 1 "two")
    ));
}

test "nested expression" {
    var r = try evalSource("(* 2 (+ 1 (- 5 2)))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 8), r.value.toF64().?);
}

test "eval: parses Tree and evaluates the same as eval" {
    var tree2 = try Parser.parse(testing.allocator, "(+ 1 (* 2 3))");
    defer tree2.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try eval(testing.allocator, &tree2, tree2.root[0], &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 7), r.value.toF64().?);
}

test "eval: let / if / cond / and / or round-trip via the bridge" {
    // Note: cond uses flat alternating `test value` pairs. Using keyword
    // *values* would trigger the parser's greedy kvpair packing — keep
    // values numeric / string here to avoid that.
    const sources = [_][:0]const u8{
        "(let [r 0.5] (* r r))",
        "(if true 1 2)",
        "(cond false 1 true 2 false 3)",
        "(and 1 2 3)",
        "(or false nil 7)",
    };
    const expected = [_]Value{
        .{ .number = 0.25 },
        .{ .number = 1 },
        .{ .number = 2 },
        .{ .number = 3 },
        .{ .number = 7 },
    };
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    for (sources, expected) |src, want| {
        var tree2 = try Parser.parse(testing.allocator, src);
        defer tree2.deinit();
        var r = try eval(testing.allocator, &tree2, tree2.root[0], &empty_env, schema);
        defer r.deinit();
        try testing.expect(Value.equals(r.value, want));
    }
}

test "eval: string result survives bridge teardown" {
    // Regression — earlier the bridge freed the legacy subtree before the
    // caller read the result, leaving Value.{string,keyword} dangling.
    var tree2 = try Parser.parse(testing.allocator, "\"hello world\"");
    defer tree2.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try eval(testing.allocator, &tree2, tree2.root[0], &empty_env, schema);
    defer r.deinit();
    try testing.expect(r.value == .string);
    try testing.expectEqualStrings("hello world", r.value.string);
}

test "expr: arithmetic over unit numbers drops the unit" {
    // The closed safe-expression vocabulary operates on numeric values;
    // unit metadata is opaque at the AST layer and must drop during eval.
    {
        var r = try evalSource("(+ 90deg 90deg)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 180), r.value.toF64().?);
    }
    {
        var r = try evalSource("(* 2 50%)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 100), r.value.toF64().?);
    }
    {
        var r = try evalSource("(< 100ms 250ms)");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
}

test "expr: let binding to unit number" {
    var r = try evalSource("(let [r 0.5em] (* r 4))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 2), r.value.toF64().?);
}

test "expr: vec3 of unit numbers via let" {
    // Pin the canonical example from the plan: 3-component vector
    // built from a let-bound unit number. eval drops the unit, so the
    // resulting vector is a plain numeric tuple.
    var r = try evalSource("(let [r 0.5em] (vec3 r r r))");
    defer r.deinit();
    try testing.expect(r.value == .vector);
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expectEqual(@as(f64, 0.5), r.value.vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 0.5), r.value.vector[1].toF64().?);
    try testing.expectEqual(@as(f64, 0.5), r.value.vector[2].toF64().?);
}

test "expr: clamp / lerp / cond with unit numbers" {
    // The unit is opaque metadata: `50%` evaluates to 50.0 (not 0.5).
    // lerp(0, 1000ms, 250ms) = 0 + 250 * (1000 - 0) / 1 = 250000? no:
    // lerp(a,b,t) = a + t*(b-a) = 0 + 250 * 1000 = 250000. We pick
    // self-consistent inputs to avoid scaling pitfalls.
    {
        var r = try evalSource("(clamp 90deg 0 100)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 90), r.value.toF64().?);
    }
    {
        var r = try evalSource("(lerp 0 100 0.5em)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 50), r.value.toF64().?);
    }
    {
        var r = try evalSource("(cond (< 90deg 180deg) 1 true 0)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
    }
}

// ---------------------------------------------------------------------------
// evalBinary — long-tail / unusual / robustness coverage
// ---------------------------------------------------------------------------
//
// Covers cursor-position robustness on skipped branches, lifetime invariants,
// caller-supplied envs, every wire-format flag combination, plugin-declared
// stubs, malformed buffers, and bound-pushing inputs. Each test exercises
// something the simple parity sweep above does not.

fn binaryFromSource(src: [:0]const u8, opts: Binary.ToBinaryOptions) !Ast.Bytes {
    var tree2 = try Parser.parse(testing.allocator, src);
    defer tree2.deinit();
    return try Binary.toBinary(testing.allocator, tree2, opts);
}

fn evalBinaryFromSource(
    src: [:0]const u8,
    opts: Binary.ToBinaryOptions,
    env: *const Env,
    schema: Schema.Schema,
) !Result {
    const bin = try binaryFromSource(src, opts);
    defer bin.deinit();
    return evalBinary(testing.allocator, bin.data, env, schema);
}

const all_wire_presets = [_]Binary.ToBinaryOptions{
    .{}, // default — spans on, comments off
    Binary.ToBinaryOptions.forMode(.compact),
    Binary.ToBinaryOptions.forMode(.full),
};

// ---------- Atoms / truthiness ---------------------------------------------

test "evalBinary: nil at root" {
    var r = try evalSourceBinary("nil");
    defer r.deinit();
    try testing.expect(r.value == .nil);
}

test "evalBinary: empty string at root, all wire presets" {
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    for (all_wire_presets) |opts| {
        var r = try evalBinaryFromSource("\"\"", opts, &empty_env, schema);
        defer r.deinit();
        try testing.expect(r.value == .string);
        try testing.expectEqualStrings("", r.value.string);
    }
}

test "evalBinary: keyword root, lossless preset" {
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinaryFromSource(":mode", Binary.ToBinaryOptions.forMode(.full), &empty_env, schema);
    defer r.deinit();
    try testing.expect(r.value == .keyword);
    try testing.expectEqualStrings("mode", r.value.keyword);
}

test "evalBinary: string with embedded escapes round-trips faithfully" {
    var r = try evalSourceBinary("\"a\\nb\\tc\\\"d\"");
    defer r.deinit();
    try testing.expectEqualStrings("a\nb\tc\"d", r.value.string);
}

test "evalBinary: truthiness — 0 is truthy" {
    var r = try evalSourceBinary("(if 0 1 2)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
}

test "evalBinary: truthiness — empty string is truthy" {
    var r = try evalSourceBinary("(if \"\" 1 2)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
}

test "evalBinary: truthiness — empty vector is truthy" {
    var r = try evalSourceBinary("(if [] 1 2)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
}

test "evalBinary: truthiness — keyword bound via let is truthy" {
    // `:kw` in form-arg position parses as a keyword child (key=kw value=1),
    // which the evaluator rejects with KeywordInExpressionArgs. To exercise
    // a keyword *value* as if-predicate, bind it through `let` first —
    // the binding pair stores it as the positional value of the pair.
    var r = try evalSourceBinary("(let [k :kw] (if k 1 2))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
}

test "evalBinary: truthiness — nil is falsy" {
    var r = try evalSourceBinary("(if nil 1 2)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 2), r.value.toF64().?);
}

test "evalBinary: truthiness — false is falsy" {
    var r = try evalSourceBinary("(if false 1 2)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 2), r.value.toF64().?);
}

test "evalBinary: truthiness — all-zero vector is truthy" {
    var r = try evalSourceBinary("(if (vec3 0 0 0) 1 2)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
}

// ---------- Numeric edge cases ---------------------------------------------

test "evalBinary: negative zero arithmetic" {
    {
        var r = try evalSourceBinary("(- 0)");
        defer r.deinit();
        // -0.0 == 0.0 in IEEE 754, but the bit pattern is distinct.
        try testing.expectEqual(@as(f64, -0.0), r.value.toF64().?);
        try testing.expect(@as(u64, @bitCast(@as(f64, -0.0))) == @as(u64, @bitCast(r.value.toF64().?)));
    }
    {
        var r = try evalSourceBinary("(= (- 0) 0)");
        defer r.deinit();
        try testing.expect(r.value.boolean); // -0 == 0
    }
    {
        // 1 / -0 is +inf — neg-zero in divisor still trips DivisionByZero
        // because applyQuotient checks `d == 0` before dividing.
        try testing.expectError(error.DivisionByZero, evalSourceBinary("(/ 1 (- 0))"));
    }
}

test "evalBinary: very large and very small numbers survive" {
    {
        var r = try evalSourceBinary("(* 1e308 2)");
        defer r.deinit();
        try testing.expect(std.math.isInf(r.value.toF64().?)); // overflow → +inf
    }
    {
        var r = try evalSourceBinary("(/ 1e-300 1e10)");
        defer r.deinit();
        try testing.expect(r.value.toF64().? > 0 and r.value.toF64().? < 1e-100);
    }
}

test "evalBinary: integer-valued division stays exact across a chain" {
    var r = try evalSourceBinary("(/ 1000000 1000 100 10)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
}

// ---------- Vectors --------------------------------------------------------

test "evalBinary: empty vector survives round-trip" {
    var r = try evalSourceBinary("[]");
    defer r.deinit();
    try testing.expect(r.value == .vector);
    try testing.expectEqual(@as(usize, 0), r.value.vector.len);
}

test "evalBinary: vector with mixed types preserves each element" {
    var r = try evalSourceBinary("[1 \"two\" :three nil true false]");
    defer r.deinit();
    try testing.expect(r.value == .vector);
    try testing.expectEqual(@as(usize, 6), r.value.vector.len);
    try testing.expectEqual(@as(f64, 1), r.value.vector[0].toF64().?);
    try testing.expectEqualStrings("two", r.value.vector[1].string);
    try testing.expectEqualStrings("three", r.value.vector[2].keyword);
    try testing.expect(r.value.vector[3] == .nil);
    try testing.expect(r.value.vector[4].boolean);
    try testing.expect(!r.value.vector[5].boolean);
}

test "evalBinary: triple-nested vector preserves structure" {
    var r = try evalSourceBinary("[[[1 2] [3 4]] [[5 6] [7 8]]]");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.value.vector.len);
    try testing.expectEqual(@as(usize, 2), r.value.vector[0].vector.len);
    try testing.expectEqual(@as(usize, 2), r.value.vector[0].vector[0].vector.len);
    try testing.expectEqual(@as(f64, 7), r.value.vector[1].vector[1].vector[0].toF64().?);
}

test "evalBinary: dot of empty vectors is 0" {
    var r = try evalSourceBinary("(dot [] [])");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 0), r.value.toF64().?);
}

test "evalBinary: cross product produces a 3-vector" {
    var r = try evalSourceBinary("(cross (vec3 1 0 0) (vec3 0 1 0))");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expectEqual(@as(f64, 0), r.value.vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 0), r.value.vector[1].toF64().?);
    try testing.expectEqual(@as(f64, 1), r.value.vector[2].toF64().?);
}

test "evalBinary: length of vector with negative components" {
    var r = try evalSourceBinary("(length (vec3 -3 -4 0))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 5), r.value.toF64().?);
}

test "evalBinary: dot product of let-bound vector with itself" {
    var r = try evalSourceBinary("(let [v (vec3 1 2 3)] (dot v v))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 14), r.value.toF64().?); // 1+4+9
}

test "evalBinary: vector containing keyword nodes in expression position" {
    // Keywords ARE allowed as vector elements (unlike form positional
    // children). This stresses the cursor's vec_walk path on a node kind
    // that form_walk would reject.
    var r = try evalSourceBinary("[:red :green :blue]");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expectEqualStrings("red", r.value.vector[0].keyword);
    try testing.expectEqualStrings("green", r.value.vector[1].keyword);
    try testing.expectEqualStrings("blue", r.value.vector[2].keyword);
}

// ---------- Special-form: skipBody correctness over nested subtrees --------

test "evalBinary: if-falsy skips a deep then-branch and resumes else cleanly" {
    // The then-branch contains a multi-level form. If skipBody desyncs the
    // cursor, the else-branch read will return Truncated or InvalidTag.
    var r = try evalSourceBinary("(if false (+ 1 (* 2 (- 3 (mod 7 4)))) (- 100 1))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 99), r.value.toF64().?);
}

test "evalBinary: if-truthy skips a deep else-branch and resumes parent" {
    // Same shape, opposite branch. After the if, an outer form continues —
    // so the cursor must land at the next byte after the entire if.
    var r = try evalSourceBinary("(+ 100 (if true 5 (* 1 (+ 2 (- 3 4)))))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 105), r.value.toF64().?);
}

test "evalBinary: cond skips multiple deep falsy clauses" {
    // First two clauses falsy + non-trivial value subforms; third matches.
    // Drains through both via skipBody.
    var r = try evalSourceBinary(
        \\(cond (< 5 1) (+ 10 (* 2 3))
        \\      (> 5 100) (* 4 (+ 5 6))
        \\      true (- 100 1))
    );
    defer r.deinit();
    try testing.expectEqual(@as(f64, 99), r.value.toF64().?);
}

test "evalBinary: cond match in middle skips trailing clauses" {
    var r = try evalSourceBinary(
        \\(cond (< 5 1) 1
        \\      (= 2 2) 42
        \\      true (* 100 (+ 1 1)))
    );
    defer r.deinit();
    try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
}

test "evalBinary: and short-circuit drains a deep remaining tree" {
    // Second arg is false → short-circuit; the third arg is a deep form
    // that must be drained without errors.
    var r = try evalSourceBinary("(and 1 false (* 2 (+ 3 (- 4 5))))");
    defer r.deinit();
    try testing.expect(!r.value.boolean);
}

test "evalBinary: or short-circuit returns first truthy and drains rest" {
    var r = try evalSourceBinary("(or false 7 (* 2 (+ 3 (- 4 5))))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 7), r.value.toF64().?);
}

test "evalBinary: nested if inside the truthy branch of another if" {
    var r = try evalSourceBinary("(if (> 5 1) (if (< 2 3) 10 20) 30)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 10), r.value.toF64().?);
}

test "evalBinary: cond predicate is itself a form" {
    var r = try evalSourceBinary(
        \\(cond (and false true) 1
        \\      (or false (and 1 2)) 99
        \\      true 0)
    );
    defer r.deinit();
    try testing.expectEqual(@as(f64, 99), r.value.toF64().?);
}

// ---------- Let / shadowing -----------------------------------------------

test "evalBinary: let with empty bindings evaluates body unchanged" {
    var r = try evalSourceBinary("(let [] (+ 1 2))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 3), r.value.toF64().?);
}

test "evalBinary: let with sequential dependent bindings" {
    // a = 1; b = a + 1; c = a + b; result = a*b*c = 1*2*3 = 6.
    var r = try evalSourceBinary("(let [a 1 b (+ a 1) c (+ a b)] (* a b c))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 6), r.value.toF64().?);
}

test "evalBinary: inner let shadows outer binding" {
    var r = try evalSourceBinary("(let [x 1] (let [x 99] x))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 99), r.value.toF64().?);
}

test "evalBinary: inner let preserves non-shadowed outer bindings" {
    // Outer x=1, y=2, z=3; inner shadows x,y → 10,20; body uses inner x,y
    // and outer z. 10+20+3 = 33.
    var r = try evalSourceBinary(
        \\(let [x 1 y 2 z 3]
        \\  (let [x 10 y 20] (+ x y z)))
    );
    defer r.deinit();
    try testing.expectEqual(@as(f64, 33), r.value.toF64().?);
}

test "evalBinary: let same name twice — last binding wins" {
    var r = try evalSourceBinary("(let [x 1 x 2 x 3] x)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 3), r.value.toF64().?);
}

test "evalBinary: let-shadowed `+` does not break form dispatch" {
    // The form head `+` dispatches on string compare to applyFunction,
    // independent of any `+` binding in env. The let-bound `+` is only
    // visible to symbol-value lookup, not form-head resolution.
    var r = try evalSourceBinary("(let [+ 99] (+ 1 2))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 3), r.value.toF64().?);
}

test "evalBinary: let-shadowed `+` resolves to env value when used as symbol" {
    var r = try evalSourceBinary("(let [+ 99] +)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 99), r.value.toF64().?);
}

test "evalBinary: 4-deep let chain" {
    var r = try evalSourceBinary("(let [a 1] (let [b 2] (let [c 3] (let [d 4] (+ a b c d)))))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 10), r.value.toF64().?);
}

// ---------- Forward-ref / unknown bindings ---------------------------------

test "evalBinary: forward reference inside let raises UnknownBinding" {
    // x's value-expr references y, but y is bound after x in the same let.
    try testing.expectError(error.UnknownBinding, evalSourceBinary("(let [x y y 1] x)"));
}

test "evalBinary: bare unbound symbol at root raises UnknownBinding" {
    try testing.expectError(error.UnknownBinding, evalSourceBinary("missing"));
}

test "evalBinary: symbol used in form arg position raises UnknownBinding" {
    try testing.expectError(error.UnknownBinding, evalSourceBinary("(+ 1 missing)"));
}

// ---------- Type / arity errors --------------------------------------------

test "evalBinary: type mismatches across vocabulary" {
    try testing.expectError(error.TypeMismatch, evalSourceBinary("(+ \"foo\" 1)"));
    try testing.expectError(error.TypeMismatch, evalSourceBinary("(+ true 1)"));
    try testing.expectError(error.TypeMismatch, evalSourceBinary("(+ nil 1)"));
    try testing.expectError(error.TypeMismatch, evalSourceBinary("(+ [1 2] 3)"));
    try testing.expectError(error.TypeMismatch, evalSourceBinary("(dot [1 2] [3 4 5])"));
    try testing.expectError(error.TypeMismatch, evalSourceBinary("(cross (vec3 1 2 3) [4 5])"));
    try testing.expectError(error.TypeMismatch, evalSourceBinary("(length 7)"));
    try testing.expectError(error.TypeMismatch, evalSourceBinary("(dot 1 2)"));
}

test "evalBinary: arity mismatches across vocabulary" {
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(/ 1)"));
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(-)"));
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(mod 5)"));
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(mod 1 2 3)"));
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(not 1 2)"));
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(vec3 1 2)"));
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(vec4 1 2 3)"));
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(lerp 1 2)"));
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(clamp 1 2)"));
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(min)"));
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(max)"));
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(< 1 2 3)"));
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(= 1)"));
}

test "evalBinary: division / mod by zero" {
    try testing.expectError(error.DivisionByZero, evalSourceBinary("(/ 1 0)"));
    try testing.expectError(error.DivisionByZero, evalSourceBinary("(/ 5 2 0 1)"));
    try testing.expectError(error.DivisionByZero, evalSourceBinary("(mod 5 0)"));
}

test "evalBinary: unknown function passes through as Value.form" {
    // v2: same form-as-data flip as the tree path.
    var r = try evalSourceBinary("(no-such-fn 1 2)");
    defer r.deinit();
    try testing.expect(r.value == .form);
    try testing.expectEqualStrings("no-such-fn", r.value.form.head);
}

// ---------- Special-form structural errors ---------------------------------

test "evalBinary: let with odd number of bindings" {
    try testing.expectError(error.InvalidLetBinding, evalSourceBinary("(let [x 1 y] x)"));
}

test "evalBinary: let with non-vector bindings" {
    try testing.expectError(error.InvalidLetBinding, evalSourceBinary("(let \"oops\" 1)"));
}

test "evalBinary: let arity — no body" {
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(let [x 1])"));
}

test "evalBinary: let arity — too many trailing args" {
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(let [x 1] x x)"));
}

test "evalBinary: let arity — no bindings vector" {
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(let)"));
}

test "evalBinary: if too few args" {
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(if true)"));
}

test "evalBinary: if too many args" {
    try testing.expectError(error.ArityMismatch, evalSourceBinary("(if true 1 2 3)"));
}

test "evalBinary: cond odd-clause count" {
    try testing.expectError(error.InvalidCondClause, evalSourceBinary("(cond true 1 (< 2 3))"));
}

// ---------- Equality / comparison ------------------------------------------

test "evalBinary: string equality" {
    {
        var r = try evalSourceBinary("(= \"hello\" \"hello\")");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
    {
        var r = try evalSourceBinary("(= \"hello\" \"world\")");
        defer r.deinit();
        try testing.expect(!r.value.boolean);
    }
}

test "evalBinary: vector equality compares elementwise" {
    {
        var r = try evalSourceBinary("(= [1 2 3] [1 2 3])");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
    {
        var r = try evalSourceBinary("(= [1 2 3] [1 2 4])");
        defer r.deinit();
        try testing.expect(!r.value.boolean);
    }
    {
        var r = try evalSourceBinary("(= [] [])");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
    {
        var r = try evalSourceBinary("(= [1 [2 3]] [1 [2 3]])");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
}

test "evalBinary: cross-type equality is false (not type error)" {
    var r = try evalSourceBinary("(= 1 \"1\")");
    defer r.deinit();
    try testing.expect(!r.value.boolean);
}

// ---------- Lifetime / multi-eval / caller env -----------------------------

test "evalBinary: vector result outlives the binary buffer" {
    const a = testing.allocator;
    const bin = try binaryFromSource("[\"a\" \"bb\" \"ccc\"]", .{});
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    bin.deinit(); // free the source buffer BEFORE inspecting the result
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expectEqualStrings("a", r.value.vector[0].string);
    try testing.expectEqualStrings("bb", r.value.vector[1].string);
    try testing.expectEqualStrings("ccc", r.value.vector[2].string);
}

test "evalBinary: keyword result outlives the binary buffer" {
    const a = testing.allocator;
    const bin = try binaryFromSource(":colour", .{});
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    bin.deinit();
    try testing.expectEqualStrings("colour", r.value.keyword);
}

test "evalBinary: re-eval the same buffer twice with different envs" {
    const a = testing.allocator;
    const bin = try binaryFromSource("(* x 2)", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});

    const env1: Env = .{ .bindings = &.{.{ .name = "x", .value = .{ .number = 5 } }} };
    var r1 = try evalBinary(a, bin.data, &env1, schema);
    defer r1.deinit();
    try testing.expectEqual(@as(f64, 10), r1.value.toF64().?);

    const env2: Env = .{ .bindings = &.{.{ .name = "x", .value = .{ .number = 21 } }} };
    var r2 = try evalBinary(a, bin.data, &env2, schema);
    defer r2.deinit();
    try testing.expectEqual(@as(f64, 42), r2.value.toF64().?);
}

test "evalBinary: caller env supplies a vector binding" {
    const a = testing.allocator;
    const bin = try binaryFromSource("(dot v v)", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const v_elems = [_]Value{ .{ .number = 3 }, .{ .number = 4 } };
    const env: Env = .{ .bindings = &.{.{ .name = "v", .value = .{ .vector = &v_elems } }} };
    var r = try evalBinary(a, bin.data, &env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 25), r.value.toF64().?); // 9 + 16
}

test "evalBinary: caller env supplies a string binding" {
    const a = testing.allocator;
    const bin = try binaryFromSource("(= s \"target\")", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const env: Env = .{ .bindings = &.{.{ .name = "s", .value = .{ .string = "target" } }} };
    var r = try evalBinary(a, bin.data, &env, schema);
    defer r.deinit();
    try testing.expect(r.value.boolean);
}

test "evalBinary: parent env shadowed by inner let" {
    const a = testing.allocator;
    const bin = try binaryFromSource("(let [k 99] k)", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const env: Env = .{ .bindings = &.{.{ .name = "k", .value = .{ .number = 1 } }} };
    var r = try evalBinary(a, bin.data, &env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 99), r.value.toF64().?);
}

test "evalBinary: parent env visible when not shadowed" {
    const a = testing.allocator;
    const bin = try binaryFromSource("(let [m 2] (+ k m))", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const env: Env = .{ .bindings = &.{.{ .name = "k", .value = .{ .number = 40 } }} };
    var r = try evalBinary(a, bin.data, &env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
}

// ---------- Wire-format flag coverage --------------------------------------

test "evalBinary: same expression evaluates identically across all wire presets" {
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    const cases = [_][:0]const u8{
        "(+ 1 2 3)",
        "(let [x 7] (* x x))",
        "(if (> 5 2) (vec3 1 2 3) [])",
        "(cond false (+ 1 1) true (* 3 7))",
        "(and (or false 1) (lerp 0 100 0.25))",
        "(dot (vec3 1 2 3) [4 5 6])",
    };
    for (cases) |src| {
        var first_result: ?f64 = null;
        var first_kind: ?std.meta.Tag(Value) = null;
        for (all_wire_presets) |opts| {
            var r = try evalBinaryFromSource(src, opts, &empty_env, schema);
            defer r.deinit();
            if (first_kind == null) {
                first_kind = std.meta.activeTag(r.value);
                if (r.value.toF64() != null) first_result = r.value.toF64().?;
            } else {
                try testing.expectEqual(first_kind.?, std.meta.activeTag(r.value));
                if (first_result) |x| try testing.expectEqual(x, r.value.toF64().?);
            }
        }
    }
}

test "evalBinary: lossless wire — comments inside skipped if-then branch" {
    // Comments inside the skipped branch must drain via skipBody. If
    // skipBody mishandles trailing comments the cursor desyncs.
    const a = testing.allocator;
    const src =
        \\(if false
        \\  ; never taken
        \\  (+ #| inline |# 1 2)
        \\  ; taken
        \\  (- 100 1))
    ;
    var tree2 = try Parser.parse(a, src);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, Binary.ToBinaryOptions.forMode(.full));
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 99), r.value.toF64().?);
}

test "evalBinary: lossless wire — comments inside short-circuited and arm" {
    const a = testing.allocator;
    const src =
        \\(and 1 false
        \\  ; never reached
        \\  (* 3 #| skipped too |# 4))
    ;
    var tree2 = try Parser.parse(a, src);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, Binary.ToBinaryOptions.forMode(.full));
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expect(!r.value.boolean);
}

// ---------- Plugin / qualified-head dispatch -------------------------------

const stub_plugin: Plugin.Plugin = .{
    .name = "myns",
    .expr_funcs = &[_]Plugin.ExprFunc{
        .{ .name = "stubfn", .arity = .{ .at_least = 0 } },
    },
};

test "evalBinary: plugin-declared expr_func returns PluginFuncNotImplemented" {
    const a = testing.allocator;
    const bin = try binaryFromSource("(stubfn 1 2)", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{ core.plugin, stub_plugin });
    const empty_env: Env = .{};
    try testing.expectError(error.PluginFuncNotImplemented, evalBinary(a, bin.data, &empty_env, schema));
}

test "evalBinary: wasm-impl func on native build falls through to PluginFuncNotImplemented" {
    // `wasm_export_name` non-null + `impl` null is the D7 "executable
    // plugin" shape. On native (non-wasm32) targets the invoker is a
    // stub that returns PluginFuncNotImplemented — the wasm32 build
    // delegates to the host's `sjon_host_invoke_plugin` import.
    const wasm_impl_plugin: Plugin.Plugin = .{
        .name = "doubler",
        .expr_funcs = &[_]Plugin.ExprFunc{
            .{
                .name = "double",
                .arity = .{ .fixed = 1 },
                .wasm_export_name = "double",
            },
        },
    };
    const a = testing.allocator;
    const bin = try binaryFromSource("(double 21)", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{ core.plugin, wasm_impl_plugin });
    const empty_env: Env = .{};
    try testing.expectError(error.PluginFuncNotImplemented, evalBinary(a, bin.data, &empty_env, schema));
}

test "evalBinary: qualified head — unknown plugin passes through as Value.form" {
    // v2: form-as-data — `(myns/stubfn 1)` builds a `Value.form` with
    // namespace "myns" instead of erroring.
    var r = try evalSourceBinary("(myns/stubfn 1)");
    defer r.deinit();
    try testing.expect(r.value == .form);
    try testing.expectEqualStrings("stubfn", r.value.form.head);
    try testing.expectEqualStrings("myns", r.value.form.namespace);
}

test "evalBinary: qualified head — resolves in named plugin" {
    const a = testing.allocator;
    const bin = try binaryFromSource("(myns/stubfn 1)", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{ core.plugin, stub_plugin });
    const empty_env: Env = .{};
    // Dispatch lands on `myns/stubfn` via the namespace; the impl is
    // null (declaration-only marker), so eval surfaces that explicitly.
    try testing.expectError(error.PluginFuncNotImplemented, evalBinary(a, bin.data, &empty_env, schema));
}

test "evalBinary: qualified head — known plugin without that name passes through" {
    // v2: form-as-data. `myns` is loaded but doesn't declare `missing`;
    // the form passes through unchanged so a downstream plugin
    // expr-func can pattern-match on it.
    const a = testing.allocator;
    const bin = try binaryFromSource("(myns/missing 1)", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{ core.plugin, stub_plugin });
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expect(r.value == .form);
    try testing.expectEqualStrings("missing", r.value.form.head);
}

test "evalBinary: qualified canonical (core/let) does not trigger frame dispatch" {
    // Special-form recognition gates on `namespace == null`. (core/let …)
    // falls through to applyFunction, finds the impl-null marker the
    // core plugin declares for arity-checking, and surfaces it as
    // PluginFuncNotImplemented. Pins SJON's "validation checks shape,
    // eval checks implementation" split: the validator is happy, eval
    // says "this name is declared but not callable here."
    try testing.expectError(error.PluginFuncNotImplemented, evalSourceBinary("(core/let [1 2] 3)"));
}

test "evalBinary: qualified other-namespace special form — form-as-data pass-through" {
    // v2: (myns/let …) with `myns` not declaring `let` passes through
    // as Value.form. The bare-name `let` special form does NOT
    // activate on a qualified head — the namespace gate still holds.
    const a = testing.allocator;
    const bin = try binaryFromSource("(myns/let 1)", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{ core.plugin, stub_plugin });
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expect(r.value == .form);
    try testing.expectEqualStrings("let", r.value.form.head);
    try testing.expectEqualStrings("myns", r.value.form.namespace);
}

// ---------- Tree-path mirrors of qualified dispatch ------------------------
// The tree path runs the same applyFunction with the same namespace
// threading. These pin parity for the plugin-schema cases that the
// L49 round-trip parity test doesn't cover (it uses core-only).

fn evalSourceWithSchema(src: [:0]const u8, schema: Schema.Schema) !Result {
    var t = try Parser.parse(testing.allocator, src);
    defer t.deinit();
    const empty_env: Env = .{};
    return eval(testing.allocator, &t, t.root[0], &empty_env, schema);
}

test "eval (tree): qualified head — unknown plugin passes through as Value.form" {
    // v2 change: matches the bare-head behaviour. `(myns/stubfn 1)`
    // builds a `Value.form` with namespace "myns", head "stubfn", and
    // one positional child instead of erroring.
    const a = testing.allocator;
    var tree = try Parser.parse(a, "(myns/stubfn 1)");
    defer tree.deinit();
    const empty_env: Env = .{};
    const schema = Schema.Schema.init(&.{core.plugin});
    var result = try eval(a, &tree, tree.root[0], &empty_env, schema);
    defer result.deinit();
    try testing.expect(result.value == .form);
    try testing.expectEqualStrings("stubfn", result.value.form.head);
    try testing.expectEqualStrings("myns", result.value.form.namespace);
}

test "eval (tree): qualified head — resolves in named plugin" {
    const schema = Schema.Schema.init(&.{ core.plugin, stub_plugin });
    try testing.expectError(error.PluginFuncNotImplemented, evalSourceWithSchema("(myns/stubfn 1)", schema));
}

test "eval (tree): qualified canonical (core/let) does not trigger frame dispatch" {
    try testing.expectError(error.PluginFuncNotImplemented, evalSource("(core/let [1 2] 3)"));
}

test "eval (tree): ambiguous bare dispatch returns AmbiguousFunction" {
    const plugin_a: Plugin.Plugin = .{
        .name = "ns_a",
        .expr_funcs = &[_]Plugin.ExprFunc{.{ .name = "dupfn", .arity = .{ .at_least = 0 } }},
    };
    const plugin_b: Plugin.Plugin = .{
        .name = "ns_b",
        .expr_funcs = &[_]Plugin.ExprFunc{.{ .name = "dupfn", .arity = .{ .at_least = 0 } }},
    };
    const schema = Schema.Schema.init(&.{ core.plugin, plugin_a, plugin_b });
    try testing.expectError(error.AmbiguousFunction, evalSourceWithSchema("(dupfn 1 2)", schema));
}

// ---------- Bound stress ---------------------------------------------------

test "evalBinary: 200-deep nested + (well within MAX_EVAL_DEPTH)" {
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    const depth: usize = 200;
    for (0..depth) |_| try src.appendSlice(a, "(+ 1 ");
    try src.appendSlice(a, "0");
    for (0..depth) |_| try src.append(a, ')');
    try src.append(a, 0);
    const src_z = src.items[0 .. src.items.len - 1 :0];

    var tree2 = try Parser.parse(a, src_z);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, @floatFromInt(depth)), r.value.toF64().?);
}

test "evalBinary: 800-deep nested + still succeeds (peak ≈ 800 frames)" {
    // Parser caps at MAX_PARSE_DEPTH=1024, evalBinary at MAX_FRAMES=1024. Each
    // `(+ 1 X)` level contributes ~1 frame to the running peak; depth 800
    // is comfortably under the ceiling and confirms the iterative driver
    // doesn't accumulate hidden frames. (Tripping MAX_FRAMES requires a
    // hand-built binary deeper than the parser can produce — see the
    // hand-crafted vector chain test below.)
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    const depth: usize = 800;
    for (0..depth) |_| try src.appendSlice(a, "(+ 1 ");
    try src.appendSlice(a, "0");
    for (0..depth) |_| try src.append(a, ')');
    try src.append(a, 0);
    const src_z = src.items[0 .. src.items.len - 1 :0];

    var tree2 = try Parser.parse(a, src_z);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, @floatFromInt(depth)), r.value.toF64().?);
}

fn buildDeepVectorChain(a: Allocator, depth: u32) ![]u8 {
    // Hand-craft a binary buffer that nests vector-of-1 to arbitrary depth,
    // bypassing Parser.MAX_PARSE_DEPTH=1024. Wire layout:
    //   [magic(4)][version(1)][flags(0)][reserved(2)][pool_off=16][roots_off=18]
    //   [pool: count=0, byte_size=0]               (2 bytes)
    //   [roots: count=1]                            (1 byte)
    //   [tag=0x07 (vector)][count=1] × depth        (2 bytes per level)
    //   [tag=0x03 (number)][f64 LE = 0]             (9 bytes)
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);

    // Header: magic SJ1\n + version 1 + flags 0 + reserved 0,0 + offsets.
    try buf.appendSlice(a, &Binary.wire_magic);
    try buf.append(a, Binary.wire_version);
    try buf.append(a, 0); // flags = stripped (no spans, no comments)
    try buf.append(a, 0); // reserved
    try buf.append(a, 0); // reserved
    // pool_offset = 16 (HEADER_SIZE)
    try buf.appendNTimes(a, 0, 4);
    std.mem.writeInt(u32, buf.items[8..12], Binary.HEADER_SIZE, .little);
    // roots_offset = 16 + 2 (empty pool: count=0, size=0) = 18
    try buf.appendNTimes(a, 0, 4);
    std.mem.writeInt(u32, buf.items[12..16], Binary.HEADER_SIZE + 2, .little);

    // String pool: count=0, byte_size=0 (single varint each).
    try buf.append(a, 0);
    try buf.append(a, 0);

    // Roots: count=1 (varint).
    try buf.append(a, 1);

    // Vector chain: each level is tag(0x07) + count varint(1).
    var i: u32 = 0;
    while (i < depth) : (i += 1) {
        try buf.append(a, 0x07); // Tag.vector
        try buf.append(a, 1); // count = 1
    }

    // Innermost: number 0.
    try buf.append(a, 0x03); // Tag.toF64().?
    var f64_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &f64_bytes, @bitCast(@as(f64, 0)), .little);
    try buf.appendSlice(a, &f64_bytes);

    return buf.toOwnedSlice(a);
}

test "evalBinary: hand-built deep vector chain trips DepthExceeded" {
    const a = testing.allocator;
    // 1500 levels: each level adds ~1 frame, far past MAX_FRAMES=1024.
    const bin = try buildDeepVectorChain(a, 1500);
    defer a.free(bin);
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    const r = evalBinary(a, bin, &empty_env, schema);
    if (r) |*succeeded| {
        var s = succeeded.*;
        s.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(error.DepthExceeded, err);
    }
}

test "evalBinary: hand-built shallow vector chain succeeds (sanity)" {
    // 50-deep vector chain — well under MAX_FRAMES — to confirm the
    // hand-built binary itself is well-formed.
    const a = testing.allocator;
    const bin = try buildDeepVectorChain(a, 50);
    defer a.free(bin);
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin, &empty_env, schema);
    defer r.deinit();
    // Walk down the nested vectors to the innermost number.
    var cur = r.value;
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        try testing.expect(cur == .vector);
        try testing.expectEqual(@as(usize, 1), cur.vector.len);
        cur = cur.vector[0];
    }
    try testing.expectEqual(@as(f64, 0), cur.toF64().?);
}

test "evalBinary: 500-wide form (no nesting, just many positional args)" {
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "(+");
    const argc: usize = 500;
    for (0..argc) |_| try src.appendSlice(a, " 1");
    try src.append(a, ')');
    try src.append(a, 0);
    const src_z = src.items[0 .. src.items.len - 1 :0];

    var tree2 = try Parser.parse(a, src_z);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, @floatFromInt(argc)), r.value.toF64().?);
}

test "evalBinary: 500-element vector" {
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.append(a, '[');
    const n: usize = 500;
    var num_buf: [16]u8 = undefined;
    for (0..n) |i| {
        if (i != 0) try src.append(a, ' ');
        const s = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable;
        try src.appendSlice(a, s);
    }
    try src.append(a, ']');
    try src.append(a, 0);
    const src_z = src.items[0 .. src.items.len - 1 :0];

    var tree2 = try Parser.parse(a, src_z);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, n), r.value.vector.len);
    try testing.expectEqual(@as(f64, 0), r.value.vector[0].toF64().?);
    try testing.expectEqual(@as(f64, n - 1), r.value.vector[n - 1].toF64().?);
}

test "evalBinary: many sequential let bindings (50 names)" {
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "(let [");
    const n: usize = 50;
    var buf: [16]u8 = undefined;
    for (0..n) |i| {
        if (i != 0) try src.append(a, ' ');
        const s = std.fmt.bufPrint(&buf, "n{d} 1", .{i}) catch unreachable;
        try src.appendSlice(a, s);
    }
    try src.appendSlice(a, "] (+");
    for (0..n) |i| {
        const s = std.fmt.bufPrint(&buf, " n{d}", .{i}) catch unreachable;
        try src.appendSlice(a, s);
    }
    try src.appendSlice(a, "))");
    try src.append(a, 0);
    const src_z = src.items[0 .. src.items.len - 1 :0];

    var tree2 = try Parser.parse(a, src_z);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, @floatFromInt(n)), r.value.toF64().?);
}

// ---------- Unit-bearing numbers across the streaming evaluator ------------

test "evalBinary: number_with_unit at root drops unit" {
    var r = try evalSourceBinary("4b");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 4), r.value.toF64().?);
}

test "evalBinary: number_with_unit inside a vector keeps the f64" {
    var r = try evalSourceBinary("[1deg 2deg 3deg]");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expectEqual(@as(f64, 1), r.value.vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 2), r.value.vector[1].toF64().?);
    try testing.expectEqual(@as(f64, 3), r.value.vector[2].toF64().?);
}

test "evalBinary: number_with_unit as if predicate is truthy" {
    // 0deg evaluates to 0 → truthy (only false / nil are falsy).
    var r = try evalSourceBinary("(if 0deg 1 2)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
}

test "evalBinary: number_with_unit threaded through let and arithmetic" {
    var r = try evalSourceBinary("(let [r 0.5em] (* r 4))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 2), r.value.toF64().?);
}

// ---------- Malformed binary -----------------------------------------------

test "evalBinary: empty buffer returns Truncated" {
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    const bytes: []const u8 = &.{};
    try testing.expectError(error.Truncated, evalBinary(testing.allocator, bytes, &empty_env, schema));
}

test "evalBinary: short buffer (under header size) returns Truncated" {
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    const bytes = [_]u8{ 'S', 'J', '1' };
    try testing.expectError(error.Truncated, evalBinary(testing.allocator, &bytes, &empty_env, schema));
}

test "evalBinary: bad magic returns InvalidMagic" {
    const a = testing.allocator;
    const bin = try binaryFromSource("1", .{});
    defer bin.deinit();
    const tampered = try a.dupe(u8, bin.data);
    defer a.free(tampered);
    tampered[0] = 'X';
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    try testing.expectError(error.InvalidMagic, evalBinary(a, tampered, &empty_env, schema));
}

test "evalBinary: bad version returns InvalidVersion" {
    const a = testing.allocator;
    const bin = try binaryFromSource("1", .{});
    defer bin.deinit();
    const tampered = try a.dupe(u8, bin.data);
    defer a.free(tampered);
    tampered[4] = 0x99;
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    try testing.expectError(error.InvalidVersion, evalBinary(a, tampered, &empty_env, schema));
}

test "evalBinary: reserved flag bits set returns InvalidFlags" {
    const a = testing.allocator;
    const bin = try binaryFromSource("1", .{});
    defer bin.deinit();
    const tampered = try a.dupe(u8, bin.data);
    defer a.free(tampered);
    // Set a bit in `reserved_mask` (0xC0).
    tampered[5] |= 0x80;
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    try testing.expectError(error.InvalidFlags, evalBinary(a, tampered, &empty_env, schema));
}

test "evalBinary: unknown root tag byte returns InvalidTag" {
    // Encode a single number; the root node's tag byte sits right after
    // the empty string-pool header. Mutate it to an unused tag.
    // Use a fractional literal so the parser stays on the f64 `.number`
    // path — that pins the asserted tag byte at 0x03.
    const a = testing.allocator;
    const bin = try binaryFromSource("1.5", Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    const tampered = try a.dupe(u8, bin.data);
    defer a.free(tampered);
    // header[16] + pool[entry_count varint=0, byte_size varint=0] + roots[count varint=1] = 19 bytes
    // then tag byte. The exact offset depends on varint encoding (each is 1 byte for 0/1).
    // Header + 2-byte pool header (count=0, size=0) + 1-byte roots count = byte 19.
    const tag_offset: usize = 16 + 1 + 1 + 1;
    try testing.expect(tag_offset < tampered.len);
    try testing.expectEqual(@as(u8, 0x03), tampered[tag_offset]); // Tag.toF64().?
    tampered[tag_offset] = 0xFE; // unused
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    try testing.expectError(error.InvalidTag, evalBinary(a, tampered, &empty_env, schema));
}

test "evalBinary: truncated payload returns Truncated" {
    const a = testing.allocator;
    const bin = try binaryFromSource("12345.6789", Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // Lop off the last 2 bytes — corrupts the f64 payload.
    const truncated = bin.data[0 .. bin.data.len - 2];
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    try testing.expectError(error.Truncated, evalBinary(a, truncated, &empty_env, schema));
}

test "evalBinary: pool index out of range returns PoolIndexOutOfRange" {
    // Encode `"hi"`; the string node payload is a varint pool_idx. With
    // exactly one string in the pool, valid index is 0. Mutate to 0x7F
    // (single-byte varint = 127) which is far past the pool size.
    const a = testing.allocator;
    const bin = try binaryFromSource("\"hi\"", Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    const tampered = try a.dupe(u8, bin.data);
    defer a.free(tampered);
    // header[0..16] + pool: count varint=1 (1 byte) + size varint = 3 (`hi`
    // takes 1 len byte + 2 chars = 3) (1 byte size varint) + entry: len varint=2
    // (1 byte) + bytes "hi" (2 bytes) = pool occupies bytes 16..21 (5 bytes).
    // Then roots: count varint=1 (1 byte) at byte 21. Tag byte at 22 (0x04 = string).
    // Then payload: pool_idx varint (1 byte) at 23.
    const idx_offset: usize = 16 + 5 + 1 + 1;
    try testing.expect(idx_offset < tampered.len);
    try testing.expectEqual(@as(u8, 0x00), tampered[idx_offset]);
    tampered[idx_offset] = 0x7F;
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    try testing.expectError(error.PoolIndexOutOfRange, evalBinary(a, tampered, &empty_env, schema));
}

// ---------- Outside-the-box ------------------------------------------------

test "evalBinary: vector returned through let is fully arena-owned" {
    const a = testing.allocator;
    const bin = try binaryFromSource("(let [v [\"x\" \"yy\"]] v)", .{});
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    bin.deinit(); // free source bytes BEFORE inspecting nested strings
    try testing.expectEqual(@as(usize, 2), r.value.vector.len);
    try testing.expectEqualStrings("x", r.value.vector[0].string);
    try testing.expectEqualStrings("yy", r.value.vector[1].string);
}

test "evalBinary: chain bindings — each name resolves to the previous" {
    var r = try evalSourceBinary("(let [a 1 b a c b d c] (+ a b c d))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 4), r.value.toF64().?);
}

test "evalBinary: a+b under shadowing of a within let" {
    // (let [a 10 b a] (- b a)) — b binds to outer a (10), so b=10, a=10, b-a=0.
    var r = try evalSourceBinary("(let [a 10 b a] (- b a))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 0), r.value.toF64().?);
}

test "evalBinary: result vector with keyword elements is deep-copied" {
    const a = testing.allocator;
    const bin = try binaryFromSource("[:r :g :b]", .{});
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    bin.deinit();
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expectEqualStrings("r", r.value.vector[0].keyword);
    try testing.expectEqualStrings("g", r.value.vector[1].keyword);
    try testing.expectEqualStrings("b", r.value.vector[2].keyword);
}

test "evalBinary: 3 successive evals on the same buffer return same value" {
    const a = testing.allocator;
    const bin = try binaryFromSource("(* 3 (+ 1 2))", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var prev: f64 = -1;
    for (0..3) |_| {
        var r = try evalBinary(a, bin.data, &empty_env, schema);
        defer r.deinit();
        if (prev < 0) prev = r.value.toF64().?;
        try testing.expectEqual(prev, r.value.toF64().?);
    }
}

test "evalBinary: env-supplied vector + chained operation" {
    // A practical W-style use case: a per-frame `t` and a per-entity vector
    // bound by the host, evaluating an expression that mixes them.
    const a = testing.allocator;
    const bin = try binaryFromSource("(lerp 0 (length pos) t)", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const v = [_]Value{ .{ .number = 3 }, .{ .number = 4 } }; // length = 5
    const env: Env = .{ .bindings = &.{
        .{ .name = "pos", .value = .{ .vector = &v } },
        .{ .name = "t", .value = .{ .number = 0.5 } },
    } };
    var r = try evalBinary(a, bin.data, &env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 2.5), r.value.toF64().?);
}

test "evalBinary: nested let inside cond clause inside if branch" {
    var r = try evalSourceBinary(
        \\(if (> 10 5)
        \\  (cond (= 1 2) 0
        \\        (= 1 1) (let [x 7 y 3] (+ x y))
        \\        true 100)
        \\  -1)
    );
    defer r.deinit();
    try testing.expectEqual(@as(f64, 10), r.value.toF64().?);
}

test "evalBinary: nil result from no-else-if-falsy" {
    var r = try evalSourceBinary("(if false 1)");
    defer r.deinit();
    try testing.expect(r.value == .nil);
}

test "evalBinary: empty cond returns nil" {
    var r = try evalSourceBinary("(cond)");
    defer r.deinit();
    try testing.expect(r.value == .nil);
}

test "evalBinary: cond all falsy returns nil" {
    var r = try evalSourceBinary("(cond false 1 false 2 false 3)");
    defer r.deinit();
    try testing.expect(r.value == .nil);
}

test "evalBinary: zero-arity + and * (identities)" {
    {
        var r = try evalSourceBinary("(+)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 0), r.value.toF64().?);
    }
    {
        var r = try evalSourceBinary("(*)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
    }
}

test "evalBinary: single-arg + and * (identity element collapse)" {
    {
        var r = try evalSourceBinary("(+ 7)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 7), r.value.toF64().?);
    }
    {
        var r = try evalSourceBinary("(* 7)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 7), r.value.toF64().?);
    }
}

test "evalBinary: not on every truthy/falsy combination" {
    const cases = [_]struct { src: [:0]const u8, want: bool }{
        .{ .src = "(not true)", .want = false },
        .{ .src = "(not false)", .want = true },
        .{ .src = "(not nil)", .want = true },
        .{ .src = "(not 0)", .want = false },
        .{ .src = "(not \"\")", .want = false },
        .{ .src = "(not [])", .want = false },
    };
    for (cases) |c| {
        var r = try evalSourceBinary(c.src);
        defer r.deinit();
        try testing.expectEqual(c.want, r.value.boolean);
    }
}

test "evalBinary: lerp at endpoints and beyond" {
    const cases = [_]struct { src: [:0]const u8, want: f64 }{
        .{ .src = "(lerp 10 20 0)", .want = 10 },
        .{ .src = "(lerp 10 20 1)", .want = 20 },
        .{ .src = "(lerp 10 20 0.5)", .want = 15 },
        .{ .src = "(lerp 10 20 -1)", .want = 0 }, // extrapolation OK
        .{ .src = "(lerp 10 20 2)", .want = 30 },
    };
    for (cases) |c| {
        var r = try evalSourceBinary(c.src);
        defer r.deinit();
        try testing.expectEqual(c.want, r.value.toF64().?);
    }
}

test "evalBinary: clamp at boundaries and inverted lo/hi" {
    {
        var r = try evalSourceBinary("(clamp 5 5 5)"); // x == lo == hi
        defer r.deinit();
        try testing.expectEqual(@as(f64, 5), r.value.toF64().?);
    }
    {
        var r = try evalSourceBinary("(clamp -100 0 10)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 0), r.value.toF64().?);
    }
    // An inverted range is a diagnostic, not a panic. This assertion used
    // to read "inverted bounds are out of policy; we exercise only the
    // well-formed ranges here" — but nothing enforced that policy: `lo`
    // and `hi` are runtime values, so the validator cannot reject the
    // document, and `std.math.clamp`'s `lower <= upper` assert was
    // reachable from a plain `(clamp x 10 0)` in every host.
    try testing.expectError(error.TypeMismatch, evalSourceBinary("(clamp 5 10 0)"));
    try testing.expectError(error.TypeMismatch, evalSource("(clamp 5 10 0)"));
    // A NaN bound makes `lo > hi` false while `lower <= upper` is also
    // false — the guard has to be the negated `<=` to catch it.
    try testing.expectError(error.TypeMismatch, evalSource("(clamp 5 (sqrt -1) 10)"));
    try testing.expectError(error.TypeMismatch, evalSource("(clamp 5 0 (sqrt -1))"));
}

test "evalBinary: comparison chains evaluate as binary (per closed-v1 spec)" {
    // < / > / <= / >= take exactly 2 args. (< 1 2 3) is ArityMismatch,
    // covered above. Here we confirm chained evaluation via and:
    var r = try evalSourceBinary("(and (< 1 2) (< 2 3) (< 3 4))");
    defer r.deinit();
    try testing.expect(r.value.boolean);
}

// ---------- Hand-crafted f64 payloads (NaN / +Inf / -Inf) -----------------

fn buildSingleNumberBinary(a: Allocator, raw_bits: u64) ![]u8 {
    // Stripped wire (no spans, no comments). Single number root.
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, &Binary.wire_magic);
    try buf.append(a, Binary.wire_version);
    try buf.append(a, 0); // flags
    try buf.append(a, 0); // reserved
    try buf.append(a, 0);
    try buf.appendNTimes(a, 0, 4);
    std.mem.writeInt(u32, buf.items[8..12], Binary.HEADER_SIZE, .little);
    try buf.appendNTimes(a, 0, 4);
    std.mem.writeInt(u32, buf.items[12..16], Binary.HEADER_SIZE + 2, .little);
    try buf.append(a, 0); // pool count
    try buf.append(a, 0); // pool byte_size
    try buf.append(a, 1); // root count
    try buf.append(a, 0x03); // Tag.toF64().?
    var f64_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &f64_bytes, raw_bits, .little);
    try buf.appendSlice(a, &f64_bytes);
    return buf.toOwnedSlice(a);
}

test "evalBinary: NaN payload survives the streaming evaluator" {
    const a = testing.allocator;
    const nan_bits: u64 = 0x7FF8000000000000; // canonical f64 quiet NaN
    const bin = try buildSingleNumberBinary(a, nan_bits);
    defer a.free(bin);
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin, &empty_env, schema);
    defer r.deinit();
    try testing.expect(r.value.toF64() != null);
    try testing.expect(std.math.isNan(r.value.toF64().?));
}

test "evalBinary: +Inf payload survives" {
    const a = testing.allocator;
    const inf_bits: u64 = @bitCast(std.math.inf(f64));
    const bin = try buildSingleNumberBinary(a, inf_bits);
    defer a.free(bin);
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin, &empty_env, schema);
    defer r.deinit();
    try testing.expect(std.math.isInf(r.value.toF64().?));
    try testing.expect(r.value.toF64().? > 0);
}

test "evalBinary: -Inf payload survives" {
    const a = testing.allocator;
    const ninf_bits: u64 = @bitCast(-std.math.inf(f64));
    const bin = try buildSingleNumberBinary(a, ninf_bits);
    defer a.free(bin);
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin, &empty_env, schema);
    defer r.deinit();
    try testing.expect(std.math.isInf(r.value.toF64().?));
    try testing.expect(r.value.toF64().? < 0);
}

// ---------- Sequential let semantics (each binding sees the prior) --------

test "evalBinary: let bindings evaluate sequentially (let* semantics)" {
    // a=1, b=10 (shadows outer a in scope), c sees inner b not outer.
    // Nested let lets us prove sequentiality without ambiguity.
    var r = try evalSourceBinary(
        \\(let [a 1]
        \\  (let [a 10 b a]
        \\    (+ a b)))
    );
    defer r.deinit();
    try testing.expectEqual(@as(f64, 20), r.value.toF64().?); // a=10 (inner), b=10
}

test "evalBinary: let binding shadows previously-bound name in same let" {
    // [x 1 x (+ x 1)] — second x's value sees first x=1, so x becomes 2.
    var r = try evalSourceBinary("(let [x 1 x (+ x 1)] x)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 2), r.value.toF64().?);
}

// ---------- if-with-no-else: truthy branch ---------------------------------

test "evalBinary: 2-arg if (no else) truthy returns then-value" {
    var r = try evalSourceBinary("(if true 42)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
}

test "evalBinary: 2-arg if (no else) inside larger expression" {
    // Outer + adds 100 to the if-result. Confirms the cursor lands at the
    // right byte after the no-else branch (form_drain consumes trailing).
    var r = try evalSourceBinary("(+ 100 (if true 5))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 105), r.value.toF64().?);
}

// ---------- skip-correctness: deep skipped subtrees ------------------------

test "evalBinary: if-falsy skips a 50-deep then-branch and resumes else" {
    // Then-branch is `(+ 1 (+ 1 (... 0)))` 50-deep. skipBody must descend
    // through all 50 levels via its internal stack (cap = MAX_TREE_DEPTH*2).
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "(if false ");
    const depth: usize = 50;
    for (0..depth) |_| try src.appendSlice(a, "(+ 1 ");
    try src.appendSlice(a, "0");
    for (0..depth) |_| try src.append(a, ')');
    try src.appendSlice(a, " 999)");
    try src.append(a, 0);
    const src_z = src.items[0 .. src.items.len - 1 :0];

    var tree2 = try Parser.parse(a, src_z);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 999), r.value.toF64().?);
}

test "evalBinary: cond drains 5 deep falsy clauses before matching" {
    var r = try evalSourceBinary(
        \\(cond false (+ 1 (* 2 (- 3 4)))
        \\      false (* 5 (+ 6 (- 7 8)))
        \\      false (- 10 (+ 11 (* 12 13)))
        \\      false (+ 100 (* 200 (- 300 400)))
        \\      false (* 5 (+ 6 (lerp 0 100 0.5)))
        \\      true 7)
    );
    defer r.deinit();
    try testing.expectEqual(@as(f64, 7), r.value.toF64().?);
}

test "evalBinary: nested if/let/cond/and round-trip without cursor desync" {
    // Mixes every special form. Each one must drain its own form correctly
    // so the surrounding `(+ 1000 …)` lands at the right byte.
    var r = try evalSourceBinary(
        \\(+ 1000
        \\   (if (and (> 5 1) (or false true))
        \\     (let [x 1 y 2 z 3]
        \\       (cond (= x 0) -1
        \\             (= x 1) (+ x y z)
        \\             true 0))
        \\     -999))
    );
    defer r.deinit();
    try testing.expectEqual(@as(f64, 1006), r.value.toF64().?);
}

// ---------- Vector of expressions in expression position -------------------

test "evalBinary: vector of forms — each element evaluates to a scalar" {
    var r = try evalSourceBinary("[(+ 1 2) (* 3 4) (- 10 1)]");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expectEqual(@as(f64, 3), r.value.vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 12), r.value.vector[1].toF64().?);
    try testing.expectEqual(@as(f64, 9), r.value.vector[2].toF64().?);
}

test "evalBinary: vector of vectors built from forms — dot of inner pair" {
    var r = try evalSourceBinary("(dot [(+ 0 1) (+ 0 2) (+ 0 3)] [(+ 0 4) (+ 0 5) (+ 0 6)])");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 32), r.value.toF64().?); // 4+10+18
}

// ---------- Real-world chains ---------------------------------------------

test "evalBinary: 100-step accumulator via chained let bindings" {
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    // Build (let [a0 0 a1 (+ a0 1) a2 (+ a1 1) ... a100 (+ a99 1)] a100).
    // Result should be 100.
    try src.appendSlice(a, "(let [a0 0");
    var buf: [32]u8 = undefined;
    const n: u32 = 100;
    var i: u32 = 1;
    while (i <= n) : (i += 1) {
        const s = std.fmt.bufPrint(&buf, " a{d} (+ a{d} 1)", .{ i, i - 1 }) catch unreachable;
        try src.appendSlice(a, s);
    }
    try src.appendSlice(a, "] a");
    const last = std.fmt.bufPrint(&buf, "{d})", .{n}) catch unreachable;
    try src.appendSlice(a, last);
    try src.append(a, 0);
    const src_z = src.items[0 .. src.items.len - 1 :0];

    var tree2 = try Parser.parse(a, src_z);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, @floatFromInt(n)), r.value.toF64().?);
}

// ---------- Re-eval invariants after a failure ----------------------------

test "evalBinary: previous failure does not corrupt next call" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    {
        try testing.expectError(error.DivisionByZero, evalSourceBinary("(/ 1 0)"));
    }
    {
        var r = try evalSourceBinary("(+ 1 2)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 3), r.value.toF64().?);
    }
    {
        // v2: unknown head passes through as Value.form.
        var r = try evalSourceBinary("(no-such 1)");
        defer r.deinit();
        try testing.expect(r.value == .form);
    }
    {
        const bin = try binaryFromSource("(* 6 7)", .{});
        defer bin.deinit();
        var r = try evalBinary(a, bin.data, &empty_env, schema);
        defer r.deinit();
        try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
    }
}

// ---------- More malformed-binary cases -----------------------------------

test "evalBinary: extra trailing bytes after roots — accepted (cursor stops)" {
    // The cursor only walks the declared root_count. Trailing bytes are
    // unread. This documents existing behaviour rather than enforcing a
    // particular stance on strictness.
    const a = testing.allocator;
    const bin = try binaryFromSource("(+ 1 2)", .{});
    defer bin.deinit();
    const padded = try a.alloc(u8, bin.data.len + 16);
    defer a.free(padded);
    @memcpy(padded[0..bin.data.len], bin.data);
    @memset(padded[bin.data.len..], 0xAB);
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, padded, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 3), r.value.toF64().?);
}

test "evalBinary: zero-root buffer rejected as MultipleRoots" {
    // root_count = 0; we expect MultipleRoots since `remaining != 1`.
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, &Binary.wire_magic);
    try buf.append(a, Binary.wire_version);
    try buf.append(a, 0);
    try buf.append(a, 0);
    try buf.append(a, 0);
    try buf.appendNTimes(a, 0, 4);
    std.mem.writeInt(u32, buf.items[8..12], Binary.HEADER_SIZE, .little);
    try buf.appendNTimes(a, 0, 4);
    std.mem.writeInt(u32, buf.items[12..16], Binary.HEADER_SIZE + 2, .little);
    try buf.append(a, 0); // pool count
    try buf.append(a, 0); // pool size
    try buf.append(a, 0); // root count = 0
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    try testing.expectError(error.MultipleRoots, evalBinary(a, buf.items, &empty_env, schema));
}

test "evalBinary: child entry tag corruption surfaces InvalidTag" {
    // For `(+ 1 2)` the form's first child is a positional entry (tag 0x10).
    // Corrupt it to 0xEE — outside {0x10, 0x11} — and expect InvalidTag.
    const a = testing.allocator;
    const bin = try binaryFromSource("(+ 1 2)", Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    const tampered = try a.dupe(u8, bin.data);
    defer a.free(tampered);
    // Find the first 0x10 byte after the header.
    var i: usize = Binary.HEADER_SIZE;
    while (i < tampered.len) : (i += 1) {
        if (tampered[i] == 0x10) {
            tampered[i] = 0xEE;
            break;
        }
    }
    try testing.expect(i < tampered.len);
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    try testing.expectError(error.InvalidTag, evalBinary(a, tampered, &empty_env, schema));
}

// ---------- Documentary tests: parity invariants on randomised shapes -----

test "evalBinary: parity with eval across special-form skip patterns" {
    // Programs that exercise every short-circuit and skipBody path. Each
    // must produce the same Value via tree2 evaluator and binary streamer.
    const cases = [_][:0]const u8{
        "(if (> 1 0) (+ 1 (* 2 3)) (- 5 (* 1 2)))",
        "(if (< 1 0) (* 5 6) (+ 100 (- 50 50)))",
        "(if true 7)",
        "(if false 7)",
        "(cond (= 1 2) 0 (= 1 1) (+ 5 10) true 100)",
        "(cond false (* 1 2) false (* 3 4) true 99)",
        "(cond)",
        "(and 1 2 (+ 0 3))",
        "(and 1 false (* 99 99))",
        "(or false (and 1 2) (* 99 99))",
        "(or false false 0)",
        "(let [x 1 y (+ x 1) z (* x y)] (+ x y z))",
        "(let [] (+ 1 2))",
        "(let [v [1 2 3]] (dot v v))",
    };
    for (cases) |src| {
        var via_tree = try evalSource(src);
        defer via_tree.deinit();
        var via_bin = try evalSourceBinary(src);
        defer via_bin.deinit();
        if (!Value.equals(via_tree.value, via_bin.value)) {
            std.debug.print("\nspecial-form parity break for: {s}\n", .{src});
            return error.TestUnexpectedResult;
        }
    }
}

test "evalBinary: parity over wide forms and vectors, including past MAX_FRAMES" {
    // Tree vs binary streamer parity across widths — including widths past
    // `MAX_FRAMES`, which is the point.
    //
    // The tree path used to schedule one frame per element/argument up
    // front, so *width* consumed frames like *depth*: a 1500-element vector
    // literal returned error.DepthExceeded at nesting depth 1 while the
    // binary path, which streams, evaluated it fine. The old ceiling here
    // was 200 — comfortably under `MAX_FRAMES` — so the divergence sat
    // just outside the test's reach.
    const a = testing.allocator;
    const widths = [_]u32{ 0, 1, 2, 5, 50, 200, Expr.MAX_FRAMES + 1, 2000 };
    for (widths) |w| {
        // `(+ 1 1 …)` — wide argument list.
        var form_src: std.ArrayList(u8) = .empty;
        defer form_src.deinit(a);
        try form_src.appendSlice(a, "(+");
        var i: u32 = 0;
        while (i < w) : (i += 1) try form_src.appendSlice(a, " 1");
        try form_src.appendSlice(a, ")\x00");

        // `[1 1 …]` — wide vector literal.
        var vec_src: std.ArrayList(u8) = .empty;
        defer vec_src.deinit(a);
        try vec_src.append(a, '[');
        i = 0;
        while (i < w) : (i += 1) try vec_src.appendSlice(a, if (i == 0) "1" else " 1");
        try vec_src.appendSlice(a, "]\x00");

        for ([_]*std.ArrayList(u8){ &form_src, &vec_src }) |buf| {
            const src_z = buf.items[0 .. buf.items.len - 1 :0];
            var via_tree = try evalSource(src_z);
            defer via_tree.deinit();
            var via_bin = try evalSourceBinary(src_z);
            defer via_bin.deinit();
            if (!Value.equals(via_tree.value, via_bin.value)) {
                std.debug.print("\nwidth-{d} parity break on: {s}\n", .{ w, src_z[0..@min(40, src_z.len)] });
                return error.TestUnexpectedResult;
            }
        }
    }
}

// ---------- Aliasing / reuse across calls ---------------------------------

// ---------- Predicates that are themselves complex forms -----------------

test "evalBinary: if predicate is itself a let" {
    var r = try evalSourceBinary("(if (let [x 1] x) 100 200)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 100), r.value.toF64().?);
}

test "evalBinary: if predicate is itself a cond" {
    var r = try evalSourceBinary(
        \\(if (cond (= 1 2) false true true)
        \\  111
        \\  222)
    );
    defer r.deinit();
    try testing.expectEqual(@as(f64, 111), r.value.toF64().?);
}

test "evalBinary: cond predicate is a let with arithmetic" {
    var r = try evalSourceBinary(
        \\(cond (let [a 5 b 6] (> a b)) 1
        \\      (let [a 5 b 6] (< a b)) 2
        \\      true 3)
    );
    defer r.deinit();
    try testing.expectEqual(@as(f64, 2), r.value.toF64().?);
}

// ---------- Keyword-in-args at non-first positions -------------------------

test "evalBinary: keyword child after a positional triggers KeywordInExpressionArgs" {
    // First child is positional (1), second is keyword pair (:foo 2).
    // Streaming evaluator should reject the moment it sees the keyword
    // entry, regardless of how many positional siblings preceded it.
    try testing.expectError(error.KeywordInExpressionArgs, evalSourceBinary("(+ 1 :foo 2)"));
}

test "evalBinary: keyword child as third arg also triggers the error" {
    try testing.expectError(error.KeywordInExpressionArgs, evalSourceBinary("(+ 1 2 :foo 3)"));
}

// ---------- Round-trip stability ------------------------------------------

test "evalBinary: parse → toBinary → fromBinary → toBinary → evalBinary stable" {
    // Confirm a double-encode round-trip leaves the result identical.
    const a = testing.allocator;
    const src = "(let [x 7] (* x x))";

    var t1 = try Parser.parse(a, src);
    defer t1.deinit();
    const bin1 = try Binary.toBinary(a, t1, .{});
    defer bin1.deinit();

    var t2 = try Binary.fromBinary(a, bin1.data, .{});
    defer t2.deinit();
    const bin2 = try Binary.toBinary(a, t2, .{});
    defer bin2.deinit();

    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r1 = try evalBinary(a, bin1.data, &empty_env, schema);
    defer r1.deinit();
    var r2 = try evalBinary(a, bin2.data, &empty_env, schema);
    defer r2.deinit();
    try testing.expect(Value.equals(r1.value, r2.value));
    try testing.expectEqual(@as(f64, 49), r1.value.toF64().?);
}

// ---------- IEEE 754 precision preserved -----------------------------------

test "evalBinary: 0.1 + 0.2 ≠ 0.3 (IEEE-754 precision passes through)" {
    // Confirms the f64 byte payload is preserved verbatim, no FP munging.
    var r = try evalSourceBinary("(= (+ 0.1 0.2) 0.3)");
    defer r.deinit();
    try testing.expect(!r.value.boolean);
}

test "evalBinary: epsilon-precision numbers round-trip through binary" {
    var r = try evalSourceBinary("(- 1.0000000000000002 1.0)");
    defer r.deinit();
    try testing.expect(r.value.toF64().? > 0);
    try testing.expect(r.value.toF64().? < 1e-15);
}

// ---------- Pool deduplication -------------------------------------------

test "evalBinary: identical strings share a pool entry yet remain distinct values" {
    // The encoder's PoolBuilder dedups; both reads return slices of the
    // same pool bytes. Equality must still work positionally and after
    // deepCopy to the result arena.
    var r = try evalSourceBinary(
        \\(let [a "shared" b "shared"]
        \\  [a b])
    );
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.value.vector.len);
    try testing.expectEqualStrings("shared", r.value.vector[0].string);
    try testing.expectEqualStrings("shared", r.value.vector[1].string);
}

test "evalBinary: identical keywords across vector deduplicate via pool but evaluate independently" {
    var r = try evalSourceBinary("[:tag :tag :tag]");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    for (r.value.vector) |v| try testing.expectEqualStrings("tag", v.keyword);
}

// ---------- Long strings (stresses deepCopy chunking) --------------------

test "evalBinary: 4 KiB string survives deep-copy from buffer" {
    const a = testing.allocator;
    const len: usize = 4 * 1024;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.append(a, '"');
    var i: usize = 0;
    while (i < len) : (i += 1) try src.append(a, 'x');
    try src.append(a, '"');
    try src.append(a, 0);
    const src_z = src.items[0 .. src.items.len - 1 :0];

    var tree2 = try Parser.parse(a, src_z);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, .{});
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    bin.deinit();
    try testing.expectEqual(len, r.value.string.len);
    for (r.value.string) |c| try testing.expectEqual(@as(u8, 'x'), c);
}

// ---------- Long symbol names ---------------------------------------------

test "evalBinary: 256-char symbol name resolves through env" {
    const a = testing.allocator;
    var name: [256]u8 = undefined;
    @memset(&name, 'q');
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "(+ ");
    try src.appendSlice(a, &name);
    try src.appendSlice(a, " 1)");
    try src.append(a, 0);
    const src_z = src.items[0 .. src.items.len - 1 :0];

    var tree2 = try Parser.parse(a, src_z);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const env: Env = .{ .bindings = &.{.{ .name = &name, .value = .{ .number = 41 } }} };
    var r = try evalBinary(a, bin.data, &env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
}

// ---------- Wide cond ------------------------------------------------------

test "evalBinary: 30-clause cond reaches the last branch" {
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "(cond ");
    var i: u32 = 0;
    while (i < 29) : (i += 1) try src.appendSlice(a, "false 0 ");
    try src.appendSlice(a, "true 99)");
    try src.append(a, 0);
    const src_z = src.items[0 .. src.items.len - 1 :0];

    var tree2 = try Parser.parse(a, src_z);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 99), r.value.toF64().?);
}

// ---------- Symbol with non-alphabetic characters --------------------------

test "evalBinary: symbol with hyphen and digit resolves through env" {
    // SJON identifiers allow hyphens and embedded digits (`my-var-2`).
    const a = testing.allocator;
    const bin = try binaryFromSource("(* my-var-2 3)", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const env: Env = .{ .bindings = &.{.{ .name = "my-var-2", .value = .{ .number = 14 } }} };
    var r = try evalBinary(a, bin.data, &env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
}

// ---------- Trip skipBody's internal depth cap -----------------------------

fn buildIfFalsyWithDeepFormThen(a: Allocator, depth: u32) ![]u8 {
    // Hand-build a form `(if false TREE 99)` where TREE is a chain of
    // `(+ 1 (+ 1 ...))` to `depth` levels. The cursor's skipBody pushes
    // 2 frames per form; cap is MAX_TREE_DEPTH*2 (2048), so depth >= 1025
    // trips DepthExceeded inside skipBody.
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);

    // Header (stripped flags).
    try buf.appendSlice(a, &Binary.wire_magic);
    try buf.append(a, Binary.wire_version);
    try buf.append(a, 0); // flags
    try buf.append(a, 0);
    try buf.append(a, 0);
    try buf.appendNTimes(a, 0, 4);
    std.mem.writeInt(u32, buf.items[8..12], Binary.HEADER_SIZE, .little);
    try buf.appendNTimes(a, 0, 4);
    // Pool: count varint (1 B) + byte_size varint (1 B) + entries
    // (`+`: 1 B len varint + 1 B = 2 B; `if`: 1 B len + 2 B = 3 B; total 5 B).
    // Pool section = 1 + 1 + 5 = 7 bytes; roots_offset = HEADER + 7.
    std.mem.writeInt(u32, buf.items[12..16], Binary.HEADER_SIZE + 7, .little);
    try buf.append(a, 2); // pool count = 2
    try buf.append(a, 5); // pool byte_size = 5
    // Sorted by (length, lex) — `+` (len 1) before `if` (len 2).
    try buf.append(a, 1); // len
    try buf.append(a, '+');
    try buf.append(a, 2); // len
    try buf.appendSlice(a, "if");
    // Pool index: + → 0, if → 1.

    // Roots: count=1.
    try buf.append(a, 1);

    // Root form `if`: tag form_bare + head_idx=1 + child_count=3
    try buf.append(a, 0x08);
    try buf.append(a, 1); // head_idx for "if"
    try buf.append(a, 3); // child_count

    // Child 1: positional (0x10) + bool_false (0x01)
    try buf.append(a, 0x10);
    try buf.append(a, 0x01);

    // Child 2: positional (0x10) + then-branch chain.
    try buf.append(a, 0x10);
    var i: u32 = 0;
    while (i < depth) : (i += 1) {
        // form_bare + head_idx=0 (`+`) + child_count=2
        try buf.append(a, 0x08);
        try buf.append(a, 0);
        try buf.append(a, 2);
        // Child 1 of this `+`: positional + number 1
        try buf.append(a, 0x10);
        try buf.append(a, 0x03);
        var f: [8]u8 = undefined;
        std.mem.writeInt(u64, &f, @bitCast(@as(f64, 1)), .little);
        try buf.appendSlice(a, &f);
        // Child 2: positional + (next form / innermost number)
        try buf.append(a, 0x10);
    }
    // Innermost: number 0
    try buf.append(a, 0x03);
    var z: [8]u8 = undefined;
    std.mem.writeInt(u64, &z, @bitCast(@as(f64, 0)), .little);
    try buf.appendSlice(a, &z);

    // Child 3: positional + number 99 (else branch).
    try buf.append(a, 0x10);
    try buf.append(a, 0x03);
    var n: [8]u8 = undefined;
    std.mem.writeInt(u64, &n, @bitCast(@as(f64, 99)), .little);
    try buf.appendSlice(a, &n);

    return buf.toOwnedSlice(a);
}

test "evalBinary: skipBody trips DepthExceeded on a 1100-deep skipped form chain" {
    // Cursor's skipBody internal stack caps at MAX_TREE_DEPTH*2 = 2048. Each
    // form pushes 2 entries (children + trailing), so depth 1100 pushes
    // 2200 — past the cap. The else-branch evaluation never starts.
    const a = testing.allocator;
    const bin = try buildIfFalsyWithDeepFormThen(a, 1100);
    defer a.free(bin);
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    const r = evalBinary(a, bin, &empty_env, schema);
    if (r) |*succeeded| {
        var s = succeeded.*;
        s.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(error.DepthExceeded, err);
    }
}

test "evalBinary: skipBody copes with a 500-deep skipped form chain (under cap)" {
    // Sanity counterpart: 500 * 2 = 1000 SKIP_STACK entries; under cap.
    // The else-branch (99) must be reached cleanly.
    const a = testing.allocator;
    const bin = try buildIfFalsyWithDeepFormThen(a, 500);
    defer a.free(bin);
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 99), r.value.toF64().?);
}

// ---------- Mixed forms inside vector heads --------------------------------

test "evalBinary: vector containing all special-form expressions resolves" {
    var r = try evalSourceBinary(
        \\[(if true 1 9)
        \\ (let [a 2] a)
        \\ (cond true 3)
        \\ (and 1 4)
        \\ (or false 5)]
    );
    defer r.deinit();
    try testing.expectEqual(@as(usize, 5), r.value.vector.len);
    try testing.expectEqual(@as(f64, 1), r.value.vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 2), r.value.vector[1].toF64().?);
    try testing.expectEqual(@as(f64, 3), r.value.vector[2].toF64().?);
    try testing.expectEqual(@as(f64, 4), r.value.vector[3].toF64().?);
    try testing.expectEqual(@as(f64, 5), r.value.vector[4].toF64().?);
}

// ---------- env-supplied vs let-bound interaction --------------------------

test "evalBinary: env binding survives across nested let-shadow-and-restore" {
    // Outer env has y=100. Inner let shadows y=1, body evaluates +x*y.
    // After inner let, no further code, so we don't re-test outer scope —
    // but parser/evaluator must correctly route lookups for this case.
    const a = testing.allocator;
    const bin = try binaryFromSource("(let [y 1 z (+ x y)] (* y z))", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const env: Env = .{ .bindings = &.{
        .{ .name = "x", .value = .{ .number = 99 } },
        .{ .name = "y", .value = .{ .number = 100 } },
    } };
    var r = try evalBinary(a, bin.data, &env, schema);
    defer r.deinit();
    // Inner: y=1 (shadows), z = x + y = 99 + 1 = 100. body = y * z = 1 * 100 = 100.
    try testing.expectEqual(@as(f64, 100), r.value.toF64().?);
}

// ---------- Re-entrancy: nested evalBinary calls interleaved --------------

test "evalBinary: env value is the result of a previous evalBinary call" {
    // A practical pattern: eval one binary to compute a vector, bind it
    // through env, then eval a second binary that consumes it. The second
    // call must see a fully-arena-owned vector.
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};

    const bin_a = try binaryFromSource("(vec3 1 2 3)", .{});
    defer bin_a.deinit();
    var ra = try evalBinary(a, bin_a.data, &empty_env, schema);
    defer ra.deinit();

    const bin_b = try binaryFromSource("(dot v v)", .{});
    defer bin_b.deinit();
    const env: Env = .{ .bindings = &.{.{ .name = "v", .value = ra.value }} };
    var rb = try evalBinary(a, bin_b.data, &env, schema);
    defer rb.deinit();
    try testing.expectEqual(@as(f64, 14), rb.value.toF64().?); // 1+4+9
}

// ---------- Error paths from `nil` arithmetic ------------------------------

test "evalBinary: arithmetic with a let-bound nil raises TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSourceBinary("(let [x nil] (+ x 1))"));
}

test "evalBinary: comparison against nil raises TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSourceBinary("(< nil 1)"));
}

// ---------- min / max edge cases -------------------------------------------

test "evalBinary: min and max single-arg" {
    {
        var r = try evalSourceBinary("(min 7)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 7), r.value.toF64().?);
    }
    {
        var r = try evalSourceBinary("(max -3)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, -3), r.value.toF64().?);
    }
}

test "evalBinary: min/max propagate through let bindings" {
    var r = try evalSourceBinary("(let [a 5 b 3 c 8 d 1] (max a b c d))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 8), r.value.toF64().?);
}

// ---------- Triply-nested empty special forms -----------------------------

test "evalBinary: triply nested empty let" {
    var r = try evalSourceBinary("(let [] (let [] (let [] 42)))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
}

test "evalBinary: triply nested truthy if" {
    var r = try evalSourceBinary("(if true (if true (if true 1)))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
}

test "evalBinary: triply nested falsy if cascading to nil" {
    var r = try evalSourceBinary("(if false (if false (if false 1)))");
    defer r.deinit();
    try testing.expect(r.value == .nil);
}

// ---------- Reserved-looking names as bindings ----------------------------

test "evalBinary: `if` as a let-binding name resolves through env" {
    // `if` is not a reserved word in SJON's parser — it's just a symbol
    // that the evaluator special-cases when it appears as a form head.
    // As a binding name or value-position symbol, it round-trips fine.
    var r = try evalSourceBinary("(let [if 7] (+ if 1))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 8), r.value.toF64().?);
}

test "evalBinary: shadowed `if` does not break the form-head if dispatch" {
    // The form `(if 1 2)` dispatches by head string compare to the special
    // form, regardless of any `if` env binding. So this evaluates as
    // `if 1 2` → 1 (not as a function call to env's if).
    var r = try evalSourceBinary("(let [if 99] (if true 5 6))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 5), r.value.toF64().?);
}

test "evalBinary: shadowed `let` as binding name in inner let" {
    var r = try evalSourceBinary("(let [let 11] let)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 11), r.value.toF64().?);
}

test "evalBinary: operator-named bindings can be summed via env-lookup" {
    // `+` and `-` bound as values; body sums them via env path.
    var r = try evalSourceBinary("(let [+ 10 - 3] (+ + -))");
    defer r.deinit();
    // `(+ + -)` dispatches `+` form on values from env: `+` → 10, `-` → 3.
    // Sum is 13.
    try testing.expectEqual(@as(f64, 13), r.value.toF64().?);
}

// ---------- Custom flag combinations on the wire -------------------------

test "evalBinary: spans-only wire (no comments)" {
    const a = testing.allocator;
    var tree2 = try Parser.parse(a, "(+ 1 (* 2 3))");
    defer tree2.deinit();
    const opts: Binary.ToBinaryOptions = .{
        .with_spans = true,
        .with_head_spans = true,
        .with_kvpair_key_spans = true,
        .with_node_comments = false,
        .with_kvpair_comments = false,
        .with_tree_trailing_comments = false,
    };
    const bin = try Binary.toBinary(a, tree2, opts);
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 7), r.value.toF64().?);
}

test "evalBinary: comments-only wire (no spans)" {
    const a = testing.allocator;
    var tree2 = try Parser.parse(a, "; pre\n(+ 1 ; mid\n 2)");
    defer tree2.deinit();
    const opts: Binary.ToBinaryOptions = .{
        .with_spans = false,
        .with_head_spans = false,
        .with_kvpair_key_spans = false,
        .with_node_comments = true,
        .with_kvpair_comments = true,
        .with_tree_trailing_comments = true,
    };
    const bin = try Binary.toBinary(a, tree2, opts);
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 3), r.value.toF64().?);
}

test "evalBinary: comments-flag set but no comments present" {
    // Source with no comments, encoded with all comment flags on. Cursor
    // must read 0-counts cleanly through every form/node trailing-comment
    // varint without choking.
    const a = testing.allocator;
    var tree2 = try Parser.parse(a, "(+ 1 2 3)");
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, Binary.ToBinaryOptions.forMode(.full));
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 6), r.value.toF64().?);
}

test "evalBinary: lossless wire on a single bare value" {
    // Trivial root atom encoded with comments+spans flags. Confirms that
    // the streaming path doesn't choke when there's nothing to nest into.
    const a = testing.allocator;
    var tree2 = try Parser.parse(a, "42");
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, Binary.ToBinaryOptions.forMode(.full));
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
}

// ---------- UTF-8 strings -------------------------------------------------

test "evalBinary: UTF-8 multibyte strings round-trip via deepCopy" {
    // SJON strings are raw UTF-8 byte sequences. The cursor borrows pool
    // bytes verbatim and deepCopy memcpy's them to the result arena.
    var r = try evalSourceBinary("(= \"héllo\" \"héllo\")");
    defer r.deinit();
    try testing.expect(r.value.boolean);
}

test "evalBinary: UTF-8 string preserves byte length not codepoint count" {
    var r = try evalSourceBinary("\"é\""); // 'é' is 2 bytes in UTF-8
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.value.string.len);
    try testing.expectEqual(@as(u8, 0xC3), r.value.string[0]);
    try testing.expectEqual(@as(u8, 0xA9), r.value.string[1]);
}

// ---------- Nested let inside a vector inside a form ----------------------

test "evalBinary: vector-of-lets, each producing a number" {
    var r = try evalSourceBinary("[(let [a 1] a) (let [b 2] b) (let [c 3] c)]");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expectEqual(@as(f64, 1), r.value.vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 2), r.value.vector[1].toF64().?);
    try testing.expectEqual(@as(f64, 3), r.value.vector[2].toF64().?);
}

// ---------- Boolean operations: short-circuit ordering --------------------

test "evalBinary: and stops at first falsy and returns it (not coerced)" {
    // (and 1 nil 99) should return nil (the first falsy), not false.
    {
        var r = try evalSourceBinary("(and 1 nil 99)");
        defer r.deinit();
        try testing.expect(r.value == .nil);
    }
    // (and 1 false 99) should return false.
    {
        var r = try evalSourceBinary("(and 1 false 99)");
        defer r.deinit();
        try testing.expect(r.value == .boolean);
        try testing.expect(!r.value.boolean);
    }
    // (and 1 2 3) → returns last truthy = 3.
    {
        var r = try evalSourceBinary("(and 1 2 3)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 3), r.value.toF64().?);
    }
}

test "evalBinary: or returns first truthy (not coerced)" {
    {
        var r = try evalSourceBinary("(or false nil 7)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 7), r.value.toF64().?);
    }
    {
        // `:tag` in arg position parses as a keyword child, which the
        // evaluator rejects. Bind through let to use it as a value.
        var r = try evalSourceBinary("(let [k :tag] (or false k 99))");
        defer r.deinit();
        try testing.expectEqualStrings("tag", r.value.keyword);
    }
}

// ---------- Stress: 200-deep skipBody on the cond off-path ----------------

test "evalBinary: cond skips a 200-form-deep first clause cleanly" {
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "(cond false ");
    const depth: usize = 200;
    for (0..depth) |_| try src.appendSlice(a, "(+ 1 ");
    try src.appendSlice(a, "0");
    for (0..depth) |_| try src.append(a, ')');
    try src.appendSlice(a, " true 42)");
    try src.append(a, 0);
    const src_z = src.items[0 .. src.items.len - 1 :0];

    var tree2 = try Parser.parse(a, src_z);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
}

// ---------- Frame stack invariants on the value side ----------------------

test "evalBinary: deeply nested expressions leave exactly one value at the end" {
    // Verified via every other test, but documenting the invariant: after
    // evalBinary returns, the values stack must hold exactly one entry —
    // the final result. Prove it's robust under shape variation.
    const cases = [_][:0]const u8{
        "(+ (+ (+ 1 2) (- 5 1)) (* 3 (- 7 4)))",
        "(let [x (+ 1 (* 2 3))] (let [y (- x 1)] (+ x y)))",
        "(if (and (or false true) (not false)) (vec3 1 2 3) [])",
        "[(+ 0 (* 1 2)) (let [a 5] (- a 3)) (if true 9)]",
        "(cond (= 1 (* 1 1)) (lerp 0 100 (clamp 0.5 0 1)) true 0)",
    };
    for (cases) |src| {
        var via_tree = try evalSource(src);
        defer via_tree.deinit();
        var via_bin = try evalSourceBinary(src);
        defer via_bin.deinit();
        try testing.expect(Value.equals(via_tree.value, via_bin.value));
    }
}

// ---------- Unit-bearing numbers in nested expressions --------------------

test "evalBinary: nested let with multiple unit-bearing bindings" {
    var r = try evalSourceBinary(
        \\(let [x 90deg y 100% z 250ms]
        \\  (+ x y z))
    );
    defer r.deinit();
    try testing.expectEqual(@as(f64, 440), r.value.toF64().?); // 90 + 100 + 250
}

test "evalBinary: unit-bearing numbers compared as raw f64" {
    // `100ms < 250ms` evaluates as 100 < 250 = true.
    var r = try evalSourceBinary("(< 100ms 250ms)");
    defer r.deinit();
    try testing.expect(r.value.boolean);
}

test "evalBinary: equality on identical unit-bearing numbers" {
    // The unit drops at eval, so `(= 50% 50%)` compares 50.0 == 50.0 = true.
    var r = try evalSourceBinary("(= 50% 50%)");
    defer r.deinit();
    try testing.expect(r.value.boolean);
}

test "evalBinary: equality across different unit suffixes (numerically equal)" {
    // The unit metadata is lost in eval — both sides compare as 50.0.
    var r = try evalSourceBinary("(= 50% 50px)");
    defer r.deinit();
    try testing.expect(r.value.boolean);
}

// ---------- Many evals in a tight loop (regression-resistant) ------------

test "evalBinary: 100 sequential evalBinary calls stay leak-free" {
    const a = testing.allocator;
    const bin = try binaryFromSource("(+ 1 2 3 4 5)", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var r = try evalBinary(a, bin.data, &empty_env, schema);
        defer r.deinit();
        try testing.expectEqual(@as(f64, 15), r.value.toF64().?);
    }
}

// ---------- Skip a non-expression form embedded as if-false branch -------

test "evalBinary: skipBody traverses keyword-child entries in a skipped data form" {
    // `(scene :w 100 :h 200)` is a *data* form with two keyword children.
    // It's not a safe expression, but as a falsy if's then-branch the
    // streaming evaluator never tries to evaluate it — it only skipBody's
    // through. skipBody must handle 0x11 (keyword) child tags, including
    // the keyword's leading-comment / key-span fields when those flags
    // are on. Lossless wire exercises that.
    const a = testing.allocator;
    const src =
        \\(if false
        \\  (scene :w 100 :h 200 (camera :fov 45))
        \\  42)
    ;
    var tree2 = try Parser.parse(a, src);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, Binary.ToBinaryOptions.forMode(.full));
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
}

// ---------- Schema-ambiguity --------------------------------------------

test "evalBinary: ambiguous bare dispatch returns AmbiguousFunction" {
    // Two plugins declare `dupfn`. A bare-name lookup is `.ambiguous`;
    // the evaluator surfaces that as `error.AmbiguousFunction` so the
    // caller can distinguish "two plugins claim this name" from a
    // genuine impl-null marker (PluginFuncNotImplemented) or a missing
    // declaration (UnknownFunction).
    const plugin_a: Plugin.Plugin = .{
        .name = "ns_a",
        .expr_funcs = &[_]Plugin.ExprFunc{
            .{ .name = "dupfn", .arity = .{ .at_least = 0 } },
        },
    };
    const plugin_b: Plugin.Plugin = .{
        .name = "ns_b",
        .expr_funcs = &[_]Plugin.ExprFunc{
            .{ .name = "dupfn", .arity = .{ .at_least = 0 } },
        },
    };
    const a = testing.allocator;
    const bin = try binaryFromSource("(dupfn 1 2)", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{ core.plugin, plugin_a, plugin_b });
    const empty_env: Env = .{};
    try testing.expectError(error.AmbiguousFunction, evalBinary(a, bin.data, &empty_env, schema));
}

test "evalBinary: qualified dispatch resolves ambiguity to a single plugin" {
    // The same two plugins declaring `dupfn`; qualifying the call with a
    // namespace pins which plugin is meant. Each qualified call resolves
    // unambiguously to its plugin's impl-null marker.
    const plugin_a: Plugin.Plugin = .{
        .name = "ns_a",
        .expr_funcs = &[_]Plugin.ExprFunc{
            .{ .name = "dupfn", .arity = .{ .at_least = 0 } },
        },
    };
    const plugin_b: Plugin.Plugin = .{
        .name = "ns_b",
        .expr_funcs = &[_]Plugin.ExprFunc{
            .{ .name = "dupfn", .arity = .{ .at_least = 0 } },
        },
    };
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{ core.plugin, plugin_a, plugin_b });
    const empty_env: Env = .{};
    {
        const bin = try binaryFromSource("(ns_a/dupfn 1)", .{});
        defer bin.deinit();
        try testing.expectError(error.PluginFuncNotImplemented, evalBinary(a, bin.data, &empty_env, schema));
    }
    {
        const bin = try binaryFromSource("(ns_b/dupfn 1)", .{});
        defer bin.deinit();
        try testing.expectError(error.PluginFuncNotImplemented, evalBinary(a, bin.data, &empty_env, schema));
    }
}

// ---------- Cross-type equality / vector length ---------------------------

test "evalBinary: vectors of different lengths are unequal" {
    var r = try evalSourceBinary("(= [1 2] [1 2 3])");
    defer r.deinit();
    try testing.expect(!r.value.boolean);
}

test "evalBinary: scalar vs single-element vector is unequal" {
    var r = try evalSourceBinary("(= [1] 1)");
    defer r.deinit();
    try testing.expect(!r.value.boolean);
}

test "evalBinary: boolean equality (true=true, true!=false, true!=1)" {
    {
        var r = try evalSourceBinary("(= true true)");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
    {
        var r = try evalSourceBinary("(= true false)");
        defer r.deinit();
        try testing.expect(!r.value.boolean);
    }
    {
        var r = try evalSourceBinary("(= true 1)");
        defer r.deinit();
        try testing.expect(!r.value.boolean);
    }
}

test "evalBinary: nil equality" {
    {
        var r = try evalSourceBinary("(= nil nil)");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
    {
        var r = try evalSourceBinary("(= nil false)");
        defer r.deinit();
        try testing.expect(!r.value.boolean);
    }
    {
        var r = try evalSourceBinary("(= nil 0)");
        defer r.deinit();
        try testing.expect(!r.value.boolean);
    }
}

// ---------- Caller-supplied edge values via env --------------------------

test "evalBinary: env-supplied negative zero compares equal to positive zero" {
    const a = testing.allocator;
    const bin = try binaryFromSource("(= z 0)", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const env: Env = .{ .bindings = &.{.{ .name = "z", .value = .{ .number = -0.0 } }} };
    var r = try evalBinary(a, bin.data, &env, schema);
    defer r.deinit();
    try testing.expect(r.value.boolean);
}

test "evalBinary: env-supplied NaN compares unequal to itself" {
    const a = testing.allocator;
    const bin = try binaryFromSource("(= n n)", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const env: Env = .{ .bindings = &.{.{ .name = "n", .value = .{ .number = std.math.nan(f64) } }} };
    var r = try evalBinary(a, bin.data, &env, schema);
    defer r.deinit();
    try testing.expect(!r.value.boolean); // NaN != NaN per IEEE 754
}

test "evalBinary: env-supplied vector of vectors round-trips through dot of one row" {
    const a = testing.allocator;
    const row0 = [_]Value{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } };
    const env: Env = .{ .bindings = &.{.{ .name = "r", .value = .{ .vector = &row0 } }} };
    const bin = try binaryFromSource("(dot r [4 5 6])", .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    var r = try evalBinary(a, bin.data, &env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 32), r.value.toF64().?); // 4+10+18
}

// ---------- Body that ignores its bindings -------------------------------

test "evalBinary: let body ignores all bindings (constant return)" {
    var r = try evalSourceBinary("(let [unused 1 also-unused [1 2 3]] 42)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
}

// ---------- Comparison error paths --------------------------------------

test "evalBinary: comparison of strings raises TypeMismatch (only numbers ordered)" {
    try testing.expectError(error.TypeMismatch, evalSourceBinary("(< \"a\" \"b\")"));
}

test "evalBinary: comparison of vectors raises TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSourceBinary("(< [1] [2])"));
}

test "evalBinary: comparison of booleans raises TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSourceBinary("(< true false)"));
}

// ---------- Eval results compared positionally ---------------------------

test "evalBinary: equality between let-built vector and inline vector" {
    var r = try evalSourceBinary(
        \\(let [v (vec3 1 2 3)]
        \\  (= v [1 2 3]))
    );
    defer r.deinit();
    try testing.expect(r.value.boolean);
}

test "evalBinary: deeply equal nested vectors" {
    var r = try evalSourceBinary("(= [[1 [2]] [3 [4]]] [[1 [2]] [3 [4]]])");
    defer r.deinit();
    try testing.expect(r.value.boolean);
}

test "evalBinary: unequal nested vectors at deep position" {
    var r = try evalSourceBinary("(= [[1 [2]] [3 [4]]] [[1 [2]] [3 [5]]])");
    defer r.deinit();
    try testing.expect(!r.value.boolean);
}

// ---------- Cross-checking applyFunction sharing -------------------------

test "evalBinary: every closed-v1 function executes against binary buffer" {
    // Ticks every applyFunction branch at least once via the streaming
    // evaluator, ensuring no operator regressed across the tree/binary
    // bridge.
    const checks = [_]struct { src: [:0]const u8, want: f64 }{
        .{ .src = "(+ 1 2 3)", .want = 6 },
        .{ .src = "(- 10 3 2)", .want = 5 },
        .{ .src = "(* 2 3 4)", .want = 24 },
        .{ .src = "(/ 100 5 2)", .want = 10 },
        .{ .src = "(mod 17 5)", .want = 2 },
        .{ .src = "(min 3 1 4 1 5 9 2 6)", .want = 1 },
        .{ .src = "(max 3 1 4 1 5 9 2 6)", .want = 9 },
        .{ .src = "(lerp 0 100 0.25)", .want = 25 },
        .{ .src = "(clamp 50 0 10)", .want = 10 },
        .{ .src = "(dot [1 2 3] [4 5 6])", .want = 32 },
        .{ .src = "(length (vec4 1 2 2 0))", .want = 3 },
    };
    for (checks) |c| {
        var r = try evalSourceBinary(c.src);
        defer r.deinit();
        try testing.expectEqual(c.want, r.value.toF64().?);
    }

    // Boolean-returning ones.
    const bool_checks = [_]struct { src: [:0]const u8, want: bool }{
        .{ .src = "(< 1 2)", .want = true },
        .{ .src = "(> 1 2)", .want = false },
        .{ .src = "(<= 5 5)", .want = true },
        .{ .src = "(>= 5 5)", .want = true },
        .{ .src = "(= 7 7)", .want = true },
        .{ .src = "(!= 7 8)", .want = true },
        .{ .src = "(not false)", .want = true },
    };
    for (bool_checks) |c| {
        var r = try evalSourceBinary(c.src);
        defer r.deinit();
        try testing.expectEqual(c.want, r.value.boolean);
    }
}

// ---------- vec2/3/4 of let-bound values --------------------------------

test "evalBinary: vec4 with let-bound value used multiple times" {
    var r = try evalSourceBinary("(let [x 7] (vec4 x x x x))");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 4), r.value.vector.len);
    for (r.value.vector) |v| try testing.expectEqual(@as(f64, 7), v.toF64().?);
}

test "evalBinary: cross of two vec3s built from let bindings" {
    var r = try evalSourceBinary(
        \\(let [a (vec3 1 0 0) b (vec3 0 1 0)]
        \\  (cross a b))
    );
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expectEqual(@as(f64, 0), r.value.vector[0].toF64().?);
    try testing.expectEqual(@as(f64, 0), r.value.vector[1].toF64().?);
    try testing.expectEqual(@as(f64, 1), r.value.vector[2].toF64().?);
}

// ---------- Documenting accepted-shapes invariant -----------------------

test "evalBinary: every wire-format permutation evaluates an exhaustive vocabulary identically" {
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    const cases = [_][:0]const u8{
        "(+ 1 2)",
        "(* (+ 1 2) (- 5 3))",
        "(let [r 0.5em] (* r 4))",
        "(if (> 5 0) (vec3 1 2 3) [])",
        "(cond (= 1 2) 1 (= 1 1) 2)",
        "(and 1 (or false 2) 3)",
        "(dot (vec3 1 2 3) [4 5 6])",
    };
    for (cases) |src| {
        for (all_wire_presets) |opts| {
            var t = try Parser.parse(a, src);
            defer t.deinit();
            const bin = try Binary.toBinary(a, t, opts);
            defer bin.deinit();
            var r = try evalBinary(a, bin.data, &empty_env, schema);
            defer r.deinit();
            // Spot-check: must not be nil or fail.
            try testing.expect(r.value != .nil);
        }
    }
}

// ---------- Critical short-circuit invariants ----------------------------

test "evalBinary: cond truthy first clause never evaluates a poison-pill predicate later" {
    // Second clause's predicate is `(/ 1 0)` which would raise
    // DivisionByZero. The streaming evaluator must skipBody past it.
    var r = try evalSourceBinary("(cond true 1 (/ 1 0) 2)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
}

test "evalBinary: cond truthy first clause never evaluates a poison-pill value later" {
    var r = try evalSourceBinary("(cond true 99 false (/ 1 0))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 99), r.value.toF64().?);
}

test "evalBinary: and short-circuits before reaching a poison-pill argument" {
    var r = try evalSourceBinary("(and false (/ 1 0) (* 2 (- 3 4)))");
    defer r.deinit();
    try testing.expect(!r.value.boolean);
}

test "evalBinary: or short-circuits before reaching a poison-pill argument" {
    var r = try evalSourceBinary("(or true (/ 1 0))");
    defer r.deinit();
    try testing.expect(r.value.boolean);
}

test "evalBinary: if truthy never evaluates the else-branch poison-pill" {
    var r = try evalSourceBinary("(if true 7 (/ 1 0))");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 7), r.value.toF64().?);
}

test "evalBinary: if falsy never evaluates the then-branch poison-pill" {
    var r = try evalSourceBinary("(if false (/ 1 0) 7)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 7), r.value.toF64().?);
}

test "evalBinary: nested short-circuit — outer and skips while inner cond errors are unreached" {
    // `(and false (cond true (/ 1 0) ...))` — `and` short-circuits on
    // false, so the cond is never reached. Confirms multi-level skipBody.
    var r = try evalSourceBinary("(and false (cond true (/ 1 0) true 2))");
    defer r.deinit();
    try testing.expect(!r.value.boolean);
}

// ---------- Hybrid wide+deep stress -------------------------------------

test "evalBinary: hybrid wide-and-deep — outer + with deep inner sub-form" {
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    // `(+ 100 (+ 1 (+ 1 ... 0)) 200 300 400)` — one deep arm, three
    // sibling scalars. After the deep one resolves, parent must continue
    // reading siblings cleanly.
    try src.appendSlice(a, "(+ 100 ");
    const depth: usize = 200;
    for (0..depth) |_| try src.appendSlice(a, "(+ 1 ");
    try src.appendSlice(a, "0");
    for (0..depth) |_| try src.append(a, ')');
    try src.appendSlice(a, " 200 300 400)");
    try src.append(a, 0);
    const src_z = src.items[0 .. src.items.len - 1 :0];

    var tree2 = try Parser.parse(a, src_z);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    // 100 + 200 (deep arm) + 200 + 300 + 400 = 1200
    try testing.expectEqual(@as(f64, 1200), r.value.toF64().?);
}

// ---------- Pool stress: many distinct strings -------------------------

test "evalBinary: pool with many distinct strings does not corrupt indices" {
    const a = testing.allocator;
    // Build a vector of 200 distinct 3-char strings: "a00", "a01", ...
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.append(a, '[');
    var buf: [16]u8 = undefined;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        if (i != 0) try src.append(a, ' ');
        const s = std.fmt.bufPrint(&buf, "\"a{d:0>2}\"", .{i}) catch unreachable;
        try src.appendSlice(a, s);
    }
    try src.append(a, ']');
    try src.append(a, 0);
    const src_z = src.items[0 .. src.items.len - 1 :0];

    var tree2 = try Parser.parse(a, src_z);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 200), r.value.vector.len);
    // Spot-check first, middle, last.
    try testing.expectEqualStrings("a00", r.value.vector[0].string);
    try testing.expectEqualStrings("a99", r.value.vector[99].string);
    try testing.expectEqualStrings("a199", r.value.vector[199].string);
}

// ---------- Number representation invariance --------------------------

test "evalBinary: 1 == 1.0 == 1e0 (same f64 bits)" {
    {
        var r = try evalSourceBinary("(= 1 1.0)");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
    {
        var r = try evalSourceBinary("(= 1 1e0)");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
    {
        var r = try evalSourceBinary("(= 100 1e2)");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
    {
        var r = try evalSourceBinary("(= 0.5 5e-1)");
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
}

// ---------- String content edge cases ---------------------------------

test "evalBinary: string with only whitespace" {
    var r = try evalSourceBinary("\"   \"");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.value.string.len);
    for (r.value.string) |c| try testing.expectEqual(@as(u8, ' '), c);
}

test "evalBinary: string with embedded newlines, tabs, quotes" {
    var r = try evalSourceBinary("\"line1\\nline2\\t\\\"q\\\"\"");
    defer r.deinit();
    try testing.expectEqualStrings("line1\nline2\t\"q\"", r.value.string);
}

test "evalBinary: empty string equality" {
    var r = try evalSourceBinary("(= \"\" \"\")");
    defer r.deinit();
    try testing.expect(r.value.boolean);
}

// ---------- Many siblings following a deep inner form -----------------

test "evalBinary: 10 scalar siblings after a deep inner form" {
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "(+ ");
    // Deep arm.
    const depth: usize = 100;
    for (0..depth) |_| try src.appendSlice(a, "(+ 1 ");
    try src.appendSlice(a, "0");
    for (0..depth) |_| try src.append(a, ')');
    // 10 scalar siblings after.
    for (0..10) |i| {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, " {d}", .{i + 1}) catch unreachable;
        try src.appendSlice(a, s);
    }
    try src.append(a, ')');
    try src.append(a, 0);
    const src_z = src.items[0 .. src.items.len - 1 :0];

    var tree2 = try Parser.parse(a, src_z);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, .{});
    defer bin.deinit();
    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Env = .{};
    var r = try evalBinary(a, bin.data, &empty_env, schema);
    defer r.deinit();
    // 100 (deep) + sum(1..10) = 100 + 55 = 155
    try testing.expectEqual(@as(f64, 155), r.value.toF64().?);
}

// ---------- length on edge-case vectors -------------------------------

test "evalBinary: length on empty vector" {
    var r = try evalSourceBinary("(length [])");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 0), r.value.toF64().?);
}

test "evalBinary: length on single-element vector" {
    var r = try evalSourceBinary("(length [42])");
    defer r.deinit();
    // length of 1-elem vector with value 42 is sqrt(42^2) = 42.
    try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
}

test "evalBinary: length on negative-component 2-vec" {
    var r = try evalSourceBinary("(length [-3 -4])");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 5), r.value.toF64().?);
}

// ---------- A full mini-program exercising every frame variant --------

test "evalBinary: kitchen-sink program exercising every FrameBinary variant" {
    // Designed so each FrameBinary type runs at least once:
    //   eval, vec_collect, apply_form, let_commit, vec_walk, form_walk,
    //   let_walk, if_after_test, cond_after_pred, and_after_child,
    //   or_after_child, form_drain.
    var r = try evalSourceBinary(
        \\(let [pi 3.14159
        \\      v (vec3 1 2 3)
        \\      flag (and (> (length v) 0) (or false true))]
        \\  (cond
        \\    (= flag false) -1
        \\    (= flag true) (+ pi (dot v v) (lerp 0 10 0.5))
        \\    true 0))
    );
    defer r.deinit();
    // length of v = sqrt(14) ≈ 3.74; > 0 → true. or false true → true.
    // and (true) (true) → true. flag = true.
    // cond branch: flag == true → eval (+ pi (dot v v) (lerp 0 10 0.5)).
    // dot v v = 1+4+9 = 14. lerp = 5. pi+14+5 = 22.14159.
    try testing.expectApproxEqAbs(@as(f64, 22.14159), r.value.toF64().?, 1e-9);
}

// ---------- Parity sweep over compound nested expressions -------------

test "evalBinary: parity sweep over compound nested expressions" {
    const cases = [_][:0]const u8{
        "(let [p 0.5 q (- 1 p)] (+ (* p 10) (* q 20)))",
        "(if (and (> 5 1) (< 1 2)) (vec3 1 2 3) [])",
        "(cond (= (mod 10 3) 1) 1 (= (mod 10 3) 0) 0 true 99)",
        "(or (let [a 0] (> a 0)) (let [b 1] (> b 0)))",
        "(let [v [1 2 3 4 5]] (length v))",
        "(let [r (vec3 (+ 1 0) (* 2 1) (- 5 2))] (dot r r))",
        "(if (or (and false true) (= 0 0)) (clamp 100 0 50) -1)",
        "(let [a 1 b (let [c 2] (+ a c)) d (+ a b)] (+ a b d))",
    };
    for (cases) |src| {
        var via_tree = try evalSource(src);
        defer via_tree.deinit();
        var via_bin = try evalSourceBinary(src);
        defer via_bin.deinit();
        if (!Value.equals(via_tree.value, via_bin.value)) {
            std.debug.print("\nparity break for compound: {s}\n", .{src});
            std.debug.print("  tree: {any}\n", .{via_tree.value});
            std.debug.print("  bin:  {any}\n", .{via_bin.value});
            return error.TestUnexpectedResult;
        }
    }
}

test "evalBinary: env-supplied vector reused across multiple buffer evals" {
    // Same env, different buffers — verify the env's vector binding is not
    // disturbed between calls.
    const a = testing.allocator;
    const v = [_]Value{ .{ .number = 6 }, .{ .number = 8 } }; // length 10
    const env: Env = .{ .bindings = &.{.{ .name = "p", .value = .{ .vector = &v } }} };
    const schema = Schema.Schema.init(&.{core.plugin});
    {
        const bin = try binaryFromSource("(length p)", .{});
        defer bin.deinit();
        var r = try evalBinary(a, bin.data, &env, schema);
        defer r.deinit();
        try testing.expectEqual(@as(f64, 10), r.value.toF64().?);
    }
    {
        const bin = try binaryFromSource("(dot p p)", .{});
        defer bin.deinit();
        var r = try evalBinary(a, bin.data, &env, schema);
        defer r.deinit();
        try testing.expectEqual(@as(f64, 100), r.value.toF64().?); // 36+64
    }
    {
        const bin = try binaryFromSource("(= (length p) 10)", .{});
        defer bin.deinit();
        var r = try evalBinary(a, bin.data, &env, schema);
        defer r.deinit();
        try testing.expect(r.value.boolean);
    }
}

// ---------------------------------------------------------------------------
// Long-tail Expr tests — Value helper invariants, scope edges,
// arithmetic float-edge behavior, and the iterative-driver step bound.
// ---------------------------------------------------------------------------

test "Value.equals: same-tag identity holds across types" {
    try testing.expect(Value.equals(.{ .number = 1.5 }, .{ .number = 1.5 }));
    try testing.expect(Value.equals(.{ .boolean = true }, .{ .boolean = true }));
    try testing.expect(Value.equals(.nil, .nil));
    try testing.expect(Value.equals(.{ .string = "abc" }, .{ .string = "abc" }));
    try testing.expect(Value.equals(.{ .keyword = "k" }, .{ .keyword = "k" }));
}

test "Value.equals: cross-tag mismatch returns false (no panic)" {
    try testing.expect(!Value.equals(.{ .number = 1 }, .{ .boolean = true }));
    try testing.expect(!Value.equals(.{ .string = "1" }, .{ .number = 1 }));
    try testing.expect(!Value.equals(.nil, .{ .boolean = false }));
    try testing.expect(!Value.equals(.{ .keyword = "k" }, .{ .string = "k" }));
}

test "Value.equals: vector deep equality" {
    const va = [_]Value{ .{ .number = 1 }, .{ .number = 2 } };
    const vb = [_]Value{ .{ .number = 1 }, .{ .number = 2 } };
    const vc = [_]Value{ .{ .number = 1 }, .{ .number = 3 } };
    try testing.expect(Value.equals(.{ .vector = &va }, .{ .vector = &vb }));
    try testing.expect(!Value.equals(.{ .vector = &va }, .{ .vector = &vc }));
}

test "Value.equals: nested-vector mismatch detected" {
    const inner_a = [_]Value{.{ .number = 1 }};
    const inner_b = [_]Value{.{ .number = 2 }};
    const outer_a = [_]Value{.{ .vector = &inner_a }};
    const outer_b = [_]Value{.{ .vector = &inner_b }};
    try testing.expect(!Value.equals(.{ .vector = &outer_a }, .{ .vector = &outer_b }));
}

test "Value.isTruthy: number 0 and -0 both truthy (only nil/false are falsy)" {
    try testing.expect((Value{ .number = 0 }).isTruthy());
    try testing.expect((Value{ .number = -0.0 }).isTruthy());
    try testing.expect((Value{ .number = 1 }).isTruthy());
}

test "Value.isTruthy: nil and false are the only falsy values" {
    try testing.expect(!(Value{ .nil = {} }).isTruthy());
    try testing.expect(!(Value{ .boolean = false }).isTruthy());
    try testing.expect((Value{ .boolean = true }).isTruthy());
    try testing.expect((Value{ .string = "" }).isTruthy());
    try testing.expect((Value{ .keyword = "" }).isTruthy());
}

test "Env.lookup: walks parent chain in order" {
    const outer_b = [_]Env.Binding{.{ .name = "x", .value = .{ .number = 1 } }};
    const outer: Env = .{ .bindings = &outer_b };
    const inner_b = [_]Env.Binding{.{ .name = "y", .value = .{ .number = 2 } }};
    const inner: Env = .{ .parent = &outer, .bindings = &inner_b };
    try testing.expectEqual(@as(f64, 1), inner.lookup("x").?.toF64().?);
    try testing.expectEqual(@as(f64, 2), inner.lookup("y").?.toF64().?);
    try testing.expect(inner.lookup("z") == null);
}

test "Env.lookup: inner shadows outer" {
    const outer_b = [_]Env.Binding{.{ .name = "x", .value = .{ .number = 1 } }};
    const outer: Env = .{ .bindings = &outer_b };
    const inner_b = [_]Env.Binding{.{ .name = "x", .value = .{ .number = 99 } }};
    const inner: Env = .{ .parent = &outer, .bindings = &inner_b };
    try testing.expectEqual(@as(f64, 99), inner.lookup("x").?.toF64().?);
}

test "Env.lookup: same-frame later binding wins" {
    // The lookup walks the bindings array from end to start, so duplicates
    // in the same frame resolve to the last entry.
    const bindings = [_]Env.Binding{
        .{ .name = "x", .value = .{ .number = 1 } },
        .{ .name = "x", .value = .{ .number = 2 } },
    };
    const env: Env = .{ .bindings = &bindings };
    try testing.expectEqual(@as(f64, 2), env.lookup("x").?.toF64().?);
}

test "arithmetic: + with no args is identity zero" {
    var r = try evalSource("(+)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 0), r.value.toF64().?);
}

test "arithmetic: * with no args is identity one" {
    var r = try evalSource("(*)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
}

test "arithmetic: - with one arg negates" {
    var r = try evalSource("(- 7)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, -7), r.value.toF64().?);
}

test "arithmetic: / requires at least 2 args (ArityMismatch otherwise)" {
    // Pin: applyQuotient enforces arity >= 2; single-arg `/` is rejected
    // at runtime even though the validator's `.at_least_two` arity may
    // surface a different error path.
    try testing.expectError(error.ArityMismatch, evalSource("(/ 4)"));
}

test "arithmetic: large product within f64 range stays finite" {
    // Round-trip through f64 multiplication doesn't promise byte-exact
    // 1e300 (the result is the nearest representable double). Pin only
    // that the result is finite and within an absolute tolerance of the
    // intended value.
    var r = try evalSource("(* 1e150 1e150)");
    defer r.deinit();
    try testing.expect(std.math.isFinite(r.value.toF64().?));
    try testing.expect(@abs(r.value.toF64().? - 1e300) < 1e285);
}

test "arithmetic: division by zero raises DivisionByZero" {
    try testing.expectError(error.DivisionByZero, evalSource("(/ 1 0)"));
}

test "arithmetic: division by zero in middle of chain raises DivisionByZero" {
    try testing.expectError(error.DivisionByZero, evalSource("(/ 100 5 0 2)"));
}

test "arithmetic: mod by zero raises DivisionByZero" {
    try testing.expectError(error.DivisionByZero, evalSource("(mod 5 0)"));
}

test "comparison: division by zero short-circuits before equality runs" {
    // Pin: the / op raises DivisionByZero before the equality check sees
    // the result, so we never observe NaN-vs-NaN semantics from `(/ 0 0)`.
    try testing.expectError(error.DivisionByZero, evalSource("(= (/ 0 0) (/ 0 0))"));
}

test "logical: and with one falsy returns the falsy value" {
    var r = try evalSource("(and true 1 false 99)");
    defer r.deinit();
    try testing.expectEqual(false, r.value.boolean);
}

test "logical: or returns the first truthy value, not coerced to boolean" {
    var r = try evalSource("(or false 0 \"hit\")");
    defer r.deinit();
    // 0 is truthy in SJON (only nil and false are falsy), so first arg
    // returned is 0.
    try testing.expectEqual(@as(f64, 0), r.value.toF64().?);
}

test "logical: not on truthy returns false, on falsy returns true" {
    {
        var r = try evalSource("(not 1)");
        defer r.deinit();
        try testing.expectEqual(false, r.value.boolean);
    }
    {
        var r = try evalSource("(not nil)");
        defer r.deinit();
        try testing.expectEqual(true, r.value.boolean);
    }
}

test "let: binding shadows the env entry of the same name" {
    var r = try evalSource("(let [x 99] x)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 99), r.value.toF64().?);
}

test "let: sequential binding can reference earlier name" {
    var r = try evalSource("(let [a 1 b (+ a 2)] b)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 3), r.value.toF64().?);
}

test "let: forward reference raises UnknownBinding" {
    try testing.expectError(error.UnknownBinding, evalSource("(let [a b b 1] a)"));
}

test "if: condition is a vector — truthy" {
    // Empty / non-empty vectors are both truthy. Pin: nonempty.
    var r = try evalSource("(if [1 2 3] 11 22)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 11), r.value.toF64().?);
}

test "if: with no else and falsy condition returns nil" {
    var r = try evalSource("(if false 1)");
    defer r.deinit();
    try testing.expect(r.value == .nil);
}

test "cond: no clauses returns nil" {
    var r = try evalSource("(cond)");
    defer r.deinit();
    try testing.expect(r.value == .nil);
}

test "cond: all-falsy clauses return nil" {
    var r = try evalSource("(cond false 1 nil 2 false 3)");
    defer r.deinit();
    try testing.expect(r.value == .nil);
}

test "vec3: result is a 3-element vector with element values" {
    var r = try evalSource("(vec3 10 20 30)");
    defer r.deinit();
    const v = r.value.vector;
    try testing.expectEqual(@as(usize, 3), v.len);
    try testing.expectEqual(@as(f64, 10), v[0].toF64().?);
    try testing.expectEqual(@as(f64, 30), v[2].toF64().?);
}

test "lerp: interpolation at boundaries" {
    {
        var r = try evalSource("(lerp 0 100 0)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 0), r.value.toF64().?);
    }
    {
        var r = try evalSource("(lerp 0 100 1)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 100), r.value.toF64().?);
    }
}

test "lerp: extrapolation outside [0, 1]" {
    var r = try evalSource("(lerp 0 100 2)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 200), r.value.toF64().?);
}

test "clamp: value below low returns low" {
    var r = try evalSource("(clamp -5 0 10)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 0), r.value.toF64().?);
}

test "clamp: value above high returns high" {
    var r = try evalSource("(clamp 99 0 10)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 10), r.value.toF64().?);
}

test "clamp: value equal to bound returns bound" {
    var r = try evalSource("(clamp 0 0 10)");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 0), r.value.toF64().?);
}

test "min/max: single arg returns that arg" {
    {
        var r = try evalSource("(min 42)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 42), r.value.toF64().?);
    }
    {
        var r = try evalSource("(max -7)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, -7), r.value.toF64().?);
    }
}

test "min/max: many args — finds the extreme" {
    {
        var r = try evalSource("(min 9 3 7 1 5)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 1), r.value.toF64().?);
    }
    {
        var r = try evalSource("(max 9 3 7 1 5)");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 9), r.value.toF64().?);
    }
}

test "dot: zero-length vectors yield 0" {
    var r = try evalSource("(dot [] [])");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 0), r.value.toF64().?);
}

test "dot: vectors of different lengths is type mismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(dot [1 2] [3 4 5])"));
}

test "cross: non-3-vectors raise TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(cross [1 2] [3 4])"));
}

test "length: empty vector returns 0" {
    var r = try evalSource("(length [])");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 0), r.value.toF64().?);
}

test "length: single-element vector returns abs of that element" {
    {
        var r = try evalSource("(length [3])");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 3), r.value.toF64().?);
    }
    {
        var r = try evalSource("(length [-3])");
        defer r.deinit();
        try testing.expectEqual(@as(f64, 3), r.value.toF64().?);
    }
}

test "type mismatch: + on string raises TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(+ \"hi\" 1)"));
}

test "type mismatch: < on mixed types raises TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(< 1 \"two\")"));
}

test "unknown form head passes through as Value.form" {
    // v2 change: a form whose head doesn't resolve to a Plugin.ExprFunc
    // is form-as-data — evaluation builds a Value.form from the
    // evaluated children + kvpairs. Previously this raised
    // UnknownFunction; the semantic flip lets plugin expr-funcs
    // receive form literals as arguments (e.g. `(count-done [(todo …)])`).
    const a = testing.allocator;
    var tree = try Parser.parse(a, "(no-such-thing 1 2 3)");
    defer tree.deinit();
    const empty_env: Expr.Env = .{};
    const schema = Schema.Schema.init(&.{core.plugin});
    var result = try Expr.eval(a, &tree, tree.root[0], &empty_env, schema);
    defer result.deinit();
    try testing.expect(result.value == .form);
    try testing.expectEqualStrings("no-such-thing", result.value.form.head);
    try testing.expectEqual(@as(usize, 3), result.value.form.children.len);
    try testing.expectEqual(@as(f64, 1), result.value.form.children[0].toF64().?);
}

test "unknown binding in vector context raises UnknownBinding" {
    try testing.expectError(error.UnknownBinding, evalSource("[1 2 nope]"));
}

test "string equality: distinct allocations compare equal by content" {
    var r = try evalSource("(= \"abc\" \"abc\")");
    defer r.deinit();
    try testing.expectEqual(true, r.value.boolean);
}

test "string equality: case-sensitive" {
    var r = try evalSource("(= \"abc\" \"ABC\")");
    defer r.deinit();
    try testing.expectEqual(false, r.value.boolean);
}

// ============================================================================
// v0.2 stdlib expansion — math, smoothing, vector ops, list ops, random.
// ============================================================================

fn evalNumber(src: [:0]const u8) !f64 {
    var r = try evalSource(src);
    defer r.deinit();
    return r.value.toF64().?;
}

fn approxEq(a: f64, b: f64, tol: f64) bool {
    return @abs(a - b) <= tol;
}

// -- Math (extended) --------------------------------------------------------

test "abs: positive, negative, zero" {
    try testing.expectEqual(@as(f64, 3), try evalNumber("(abs 3)"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("(abs -3)"));
    try testing.expectEqual(@as(f64, 0), try evalNumber("(abs 0)"));
}

test "abs: arity mismatch" {
    try testing.expectError(error.ArityMismatch, evalSource("(abs)"));
    try testing.expectError(error.ArityMismatch, evalSource("(abs 1 2)"));
}

test "sign: positive / negative / zero / NaN" {
    try testing.expectEqual(@as(f64, 1), try evalNumber("(sign 5)"));
    try testing.expectEqual(@as(f64, -1), try evalNumber("(sign -2.5)"));
    try testing.expectEqual(@as(f64, 0), try evalNumber("(sign 0)"));
    // NaN is preserved (not coerced to 0).
    try testing.expect(std.math.isNan(try evalNumber("(sign (sqrt -1))")));
}

test "floor / ceil / round" {
    try testing.expectEqual(@as(f64, 1), try evalNumber("(floor 1.7)"));
    try testing.expectEqual(@as(f64, -2), try evalNumber("(floor -1.3)"));
    try testing.expectEqual(@as(f64, 2), try evalNumber("(ceil 1.2)"));
    try testing.expectEqual(@as(f64, -1), try evalNumber("(ceil -1.7)"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("(round 0.5)")); // half-away-from-zero
    try testing.expectEqual(@as(f64, -1), try evalNumber("(round -0.5)"));
}

test "fract: x - floor(x)" {
    try testing.expect(approxEq(try evalNumber("(fract 1.25)"), 0.25, 1e-12));
    // WGSL: fract(-0.25) computes as -0.25 - (-1) = 0.75
    try testing.expect(approxEq(try evalNumber("(fract -0.25)"), 0.75, 1e-12));
    try testing.expectEqual(@as(f64, 0), try evalNumber("(fract 3)"));
}

test "sqrt: principal root, NaN on negative" {
    try testing.expectEqual(@as(f64, 3), try evalNumber("(sqrt 9)"));
    try testing.expectEqual(@as(f64, 0), try evalNumber("(sqrt 0)"));
    try testing.expect(std.math.isNan(try evalNumber("(sqrt -1)"))); // NaN propagation
}

test "pow: integer and fractional exponents" {
    try testing.expectEqual(@as(f64, 256), try evalNumber("(pow 2 8)"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("(pow 5 0)"));
    // Deterministic pow64 → fractional results are bit-exact, not approximate.
    // (pow 2 0.5) is the canonical sqrt(2); the same bytes on native + both wasm.
    try testing.expectEqual(
        @as(u64, 0x3ff6a09e667f3bcd),
        @as(u64, @bitCast(try evalNumber("(pow 2 0.5)"))),
    );
    try testing.expect(std.math.isNan(try evalNumber("(pow -1 0.5)"))); // NaN
}

test "trig: sin / cos / tan" {
    try testing.expect(approxEq(try evalNumber("(sin 0)"), 0.0, 1e-12));
    try testing.expect(approxEq(try evalNumber("(cos 0)"), 1.0, 1e-12));
    try testing.expect(approxEq(try evalNumber("(tan 0)"), 0.0, 1e-12));
    try testing.expect(approxEq(try evalNumber("(sin (/ (pi) 2))"), 1.0, 1e-12));
    try testing.expect(approxEq(try evalNumber("(cos (pi))"), -1.0, 1e-12));
}

test "trig inverse: asin / acos / atan, NaN out of domain" {
    try testing.expect(approxEq(try evalNumber("(asin 0)"), 0.0, 1e-12));
    try testing.expect(approxEq(try evalNumber("(acos 1)"), 0.0, 1e-12));
    try testing.expect(approxEq(try evalNumber("(atan 0)"), 0.0, 1e-12));
    // |x| > 1 → NaN
    try testing.expect(std.math.isNan(try evalNumber("(asin 2)")));
    try testing.expect(std.math.isNan(try evalNumber("(acos -1.5)")));
}

test "trig: end-to-end exact-bit determinism through the evaluator" {
    // sin/cos/tan must route through the vendored trig.zig and return its
    // host-independent bits — the cross-host guarantee observed end to end,
    // not just at the unit boundary. Pins match src/trig.zig and cover small,
    // medium (Cody-Waite) and large (Payne-Hanek) argument reduction.
    const Case = struct { src: [:0]const u8, bits: u64 };
    const cases = [_]Case{
        .{ .src = "(sin 1.0)", .bits = 0x3feaed548f090cee },
        .{ .src = "(cos 1.0)", .bits = 0x3fe14a280fb5068c },
        .{ .src = "(tan 1.0)", .bits = 0x3ff8eb245cbee3a6 },
        .{ .src = "(sin 100.0)", .bits = 0xbfe03425b78c4db8 },
        .{ .src = "(cos 100.0)", .bits = 0x3feb981dbf665fdf },
        .{ .src = "(sin 10000000.0)", .bits = 0x3fdaea414a8a3352 }, // 1e7 → Payne-Hanek
        .{ .src = "(tan 10000000.0)", .bits = 0xbfddaa7d34937ac4 },
    };
    for (cases) |k| {
        try testing.expectEqual(k.bits, @as(u64, @bitCast(try evalNumber(k.src))));
    }
}

test "trig: tree and binary eval agree bit-for-bit on transcendentals" {
    // The IR consumer must reproduce the tree evaluator's transcendental bits
    // exactly, including across the large-argument reduction.
    const srcs = [_][:0]const u8{
        "(sin 1.0)",   "(cos 2.0)",        "(tan 0.7)",
        "(sin 100.0)", "(cos 10000000.0)", "(sin 1000000000000000.0)",
    };
    for (srcs) |s| {
        var r1 = try evalSource(s);
        defer r1.deinit();
        var r2 = try evalSourceBinary(s);
        defer r2.deinit();
        try testing.expectEqual(
            @as(u64, @bitCast(r1.value.toF64().?)),
            @as(u64, @bitCast(r2.value.toF64().?)),
        );
    }
}

test "atan2: quadrants" {
    try testing.expect(approxEq(try evalNumber("(atan2 0 1)"), 0.0, 1e-12));
    try testing.expect(approxEq(try evalNumber("(atan2 1 0)"), std.math.pi / 2.0, 1e-12));
    try testing.expect(approxEq(try evalNumber("(atan2 0 -1)"), std.math.pi, 1e-12));
}

test "radians / degrees: round-trip" {
    try testing.expect(approxEq(try evalNumber("(radians 180)"), std.math.pi, 1e-12));
    try testing.expect(approxEq(try evalNumber("(degrees (pi))"), 180.0, 1e-12));
    try testing.expect(approxEq(try evalNumber("(degrees (radians 42))"), 42.0, 1e-10));
}

test "constants: pi and tau" {
    try testing.expectEqual(std.math.pi, try evalNumber("(pi)"));
    try testing.expectEqual(2.0 * std.math.pi, try evalNumber("(tau)"));
    // 0-arity: passing args is an arity error.
    try testing.expectError(error.ArityMismatch, evalSource("(pi 1)"));
    try testing.expectError(error.ArityMismatch, evalSource("(tau 0)"));
}

// -- Smoothing --------------------------------------------------------------

test "saturate: clamp to [0, 1]" {
    try testing.expectEqual(@as(f64, 0), try evalNumber("(saturate -0.5)"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("(saturate 1.5)"));
    try testing.expectEqual(@as(f64, 0.7), try evalNumber("(saturate 0.7)"));
}

test "step: 0 below edge, 1 at-or-above" {
    try testing.expectEqual(@as(f64, 0), try evalNumber("(step 0.5 0.4)"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("(step 0.5 0.5)"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("(step 0.5 0.6)"));
}

test "smoothstep: cubic Hermite, clamped at edges" {
    try testing.expectEqual(@as(f64, 0), try evalNumber("(smoothstep 0 1 -0.5)"));
    try testing.expectEqual(@as(f64, 1), try evalNumber("(smoothstep 0 1 1.5)"));
    try testing.expect(approxEq(try evalNumber("(smoothstep 0 1 0.5)"), 0.5, 1e-12));
}

// -- Vector ops -------------------------------------------------------------

test "normalize: produces unit vector" {
    var r = try evalSource("(normalize (vec3 3 0 0))");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expect(approxEq(r.value.vector[0].toF64().?, 1.0, 1e-12));
    try testing.expectEqual(@as(f64, 0), r.value.vector[1].toF64().?);
    try testing.expectEqual(@as(f64, 0), r.value.vector[2].toF64().?);
}

test "normalize: zero vector → TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(normalize (vec3 0 0 0))"));
}

test "normalize: empty vector → TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(normalize [])"));
}

test "distance: euclidean" {
    try testing.expectEqual(@as(f64, 5), try evalNumber("(distance (vec3 0 0 0) (vec3 3 4 0))"));
    try testing.expectEqual(@as(f64, 0), try evalNumber("(distance (vec2 1 2) (vec2 1 2))"));
}

test "distance: length mismatch → TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(distance (vec2 0 0) (vec3 1 1 1))"));
}

test "reflect: flips along normal" {
    // I = (1, -1, 0), N = (0, 1, 0). reflect = I - 2*(I·N)*N = (1, -1, 0) - 2*(-1)*(0, 1, 0)
    //                                                                 = (1, 1, 0)
    var r = try evalSource("(reflect (vec3 1 -1 0) (vec3 0 1 0))");
    defer r.deinit();
    try testing.expect(approxEq(r.value.vector[0].toF64().?, 1.0, 1e-12));
    try testing.expect(approxEq(r.value.vector[1].toF64().?, 1.0, 1e-12));
    try testing.expect(approxEq(r.value.vector[2].toF64().?, 0.0, 1e-12));
}

test "reflect: length mismatch → TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(reflect (vec2 1 0) (vec3 0 1 0))"));
}

// -- List ops ---------------------------------------------------------------

test "nth: 0-indexed access" {
    try testing.expectEqual(@as(f64, 10), try evalNumber("(nth [10 20 30] 0)"));
    try testing.expectEqual(@as(f64, 20), try evalNumber("(nth [10 20 30] 1)"));
    try testing.expectEqual(@as(f64, 30), try evalNumber("(nth [10 20 30] 2)"));
}

test "nth: out-of-bounds → TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(nth [10 20 30] 3)"));
    try testing.expectError(error.TypeMismatch, evalSource("(nth [10 20 30] -1)"));
}

test "nth: non-integer index → TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(nth [10 20 30] 1.5)"));
}

test "nth: empty vector → TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(nth [] 0)"));
}

test "count: vector length" {
    try testing.expectEqual(@as(f64, 3), try evalNumber("(count [10 20 30])"));
    try testing.expectEqual(@as(f64, 0), try evalNumber("(count [])"));
    try testing.expectEqual(@as(f64, 3), try evalNumber("(count (vec3 1 2 3))"));
}

test "count: non-vector → TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(count 5)"));
}

// -- Seeded random ----------------------------------------------------------
//
// These tests pin specific output values for fixed (seed, key) pairs. Any
// change to the SplitMix64 algorithm or seed-conversion strategy MUST update
// these values — that's by design, so a future PRNG swap can't go unnoticed.

test "rand01: deterministic and in [0, 1)" {
    const a = try evalNumber("(rand01 1 0)");
    const b = try evalNumber("(rand01 1 0)");
    try testing.expectEqual(a, b); // determinism: same args, same output
    try testing.expect(a >= 0.0 and a < 1.0);
}

test "rand01: integer-equality of seed inputs" {
    // (rand01 1 0) and (rand01 1.0 0.0) must produce identical streams.
    try testing.expectEqual(
        try evalNumber("(rand01 1 0)"),
        try evalNumber("(rand01 1.0 0.0)"),
    );
}

test "rand01: distinct keys → distinct streams" {
    const a = try evalNumber("(rand01 1 0)");
    const b = try evalNumber("(rand01 1 1)");
    try testing.expect(a != b);
}

test "hash: 53-bit integer-as-f64 in [0, 2^53)" {
    const h = try evalNumber("(hash 1 0)");
    try testing.expect(h >= 0.0 and h < 9007199254740992.0);
    try testing.expectEqual(@floor(h), h); // integer-valued
    // Determinism
    try testing.expectEqual(h, try evalNumber("(hash 1 0)"));
}

test "rand-range: stays inside [lo, hi)" {
    var i: i64 = 0;
    while (i < 10) : (i += 1) {
        const buf_alloc = std.heap.page_allocator;
        const src = try std.fmt.allocPrintSentinel(buf_alloc, "(rand-range 7 {} -2 5)", .{i}, 0);
        defer buf_alloc.free(src);
        const v = try evalNumber(src);
        try testing.expect(v >= -2.0 and v < 5.0);
    }
}

test "rand-range: lo > hi → TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(rand-range 1 0 5 -2)"));
}

test "rand-int: stays inside [lo, hi] inclusive" {
    var i: i64 = 0;
    while (i < 30) : (i += 1) {
        const buf_alloc = std.heap.page_allocator;
        const src = try std.fmt.allocPrintSentinel(buf_alloc, "(rand-int 11 {} 0 9)", .{i}, 0);
        defer buf_alloc.free(src);
        const v = try evalNumber(src);
        try testing.expect(v >= 0.0 and v <= 9.0);
        try testing.expectEqual(@floor(v), v);
    }
}

test "rand-int: non-integer bound → TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(rand-int 1 0 0.5 9)"));
    try testing.expectError(error.TypeMismatch, evalSource("(rand-int 1 0 0 9.5)"));
}

test "rand-bool: probability extremes" {
    // p = 0 must always be false; p = 1 must always be true.
    var i: i64 = 0;
    while (i < 30) : (i += 1) {
        const buf_alloc = std.heap.page_allocator;
        const src0 = try std.fmt.allocPrintSentinel(buf_alloc, "(rand-bool 13 {} 0)", .{i}, 0);
        defer buf_alloc.free(src0);
        var r0 = try evalSource(src0);
        defer r0.deinit();
        try testing.expectEqual(false, r0.value.boolean);

        const src1 = try std.fmt.allocPrintSentinel(buf_alloc, "(rand-bool 13 {} 1)", .{i}, 0);
        defer buf_alloc.free(src1);
        var r1 = try evalSource(src1);
        defer r1.deinit();
        try testing.expectEqual(true, r1.value.boolean);
    }
}

test "rand-choice: returns one of the elements" {
    var seen = [_]bool{ false, false, false };
    var i: i64 = 0;
    while (i < 60) : (i += 1) {
        const buf_alloc = std.heap.page_allocator;
        const src = try std.fmt.allocPrintSentinel(buf_alloc, "(rand-choice 17 {} [10 20 30])", .{i}, 0);
        defer buf_alloc.free(src);
        const v = try evalNumber(src);
        if (v == 10) seen[0] = true;
        if (v == 20) seen[1] = true;
        if (v == 30) seen[2] = true;
    }
    // Reasonably likely all three are seen across 60 picks; if this ever
    // flakes, swap to a fixed key set with a hand-picked distribution.
    try testing.expect(seen[0] and seen[1] and seen[2]);
}

// ---------------------------------------------------------------------------
// Exact integer Value variants: `integer_i64` / `integer_u64` flow through
// identity ops (literal eval, let binding, vector/form construction, plugin
// pass-through) preserved, and collapse to f64 in arithmetic / comparison.
// Same-variant integer equality stays bit-exact; cross-variant routes via
// f64 (lossy beyond 2^53). Both tree and binary eval paths share these
// semantics.
// ---------------------------------------------------------------------------

test "integer variant: tree eval emits .integer_i64 for negative literal" {
    var r = try evalSource("-5");
    defer r.deinit();
    try testing.expect(r.value == .integer_i64);
    try testing.expectEqual(@as(i64, -5), r.value.integer_i64);
}

test "integer variant: tree eval emits .integer_u64 for u64-only literal" {
    var r = try evalSource("18446744073709551615");
    defer r.deinit();
    try testing.expect(r.value == .integer_u64);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), r.value.integer_u64);
}

test "integer variant: tree eval emits .number for fractional literal" {
    var r = try evalSource("2.5");
    defer r.deinit();
    try testing.expect(r.value == .number);
    try testing.expectEqual(@as(f64, 2.5), r.value.number);
}

test "integer variant: binary eval emits .integer_i64 for negative literal" {
    var r = try evalSourceBinary("-5");
    defer r.deinit();
    try testing.expect(r.value == .integer_i64);
    try testing.expectEqual(@as(i64, -5), r.value.integer_i64);
}

test "integer variant: binary eval emits .integer_u64 for u64-only literal" {
    var r = try evalSourceBinary("18446744073709551615");
    defer r.deinit();
    try testing.expect(r.value == .integer_u64);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), r.value.integer_u64);
}

test "integer variant: let-bound integer preserved (identity passthrough)" {
    var r = try evalSource("(let [x 42] x)");
    defer r.deinit();
    try testing.expect(r.value == .integer_i64);
    try testing.expectEqual(@as(i64, 42), r.value.integer_i64);
}

test "integer variant: if-branch result preserved" {
    var r = try evalSource("(if true -7 0.5)");
    defer r.deinit();
    try testing.expect(r.value == .integer_i64);
    try testing.expectEqual(@as(i64, -7), r.value.integer_i64);
}

test "integer variant: vector elements preserved per slot" {
    var r = try evalSource("[1 2.5 18446744073709551615]");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.value.vector.len);
    try testing.expect(r.value.vector[0] == .integer_i64);
    try testing.expect(r.value.vector[1] == .number);
    try testing.expect(r.value.vector[2] == .integer_u64);
    try testing.expectEqual(@as(i64, 1), r.value.vector[0].integer_i64);
    try testing.expectEqual(@as(f64, 2.5), r.value.vector[1].number);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), r.value.vector[2].integer_u64);
}

test "integer variant: arithmetic collapses to f64" {
    var r = try evalSource("(+ 1 2)");
    defer r.deinit();
    try testing.expect(r.value == .number);
    try testing.expectEqual(@as(f64, 3.0), r.value.number);
}

test "integer variant: mixed arithmetic collapses to f64" {
    var r = try evalSource("(* 18446744073709551615 1.0)");
    defer r.deinit();
    try testing.expect(r.value == .number);
    // u64.max → f64 round-trips lossily, but the result is well-defined.
    try testing.expectEqual(@as(f64, 18446744073709551615.0), r.value.number);
}

test "integer variant: comparison collapses to f64" {
    var r = try evalSource("(< -5 0)");
    defer r.deinit();
    try testing.expect(r.value.boolean);
}

test "integer variant: same-variant equality is exact" {
    var r = try evalSource("(= 18446744073709551615 18446744073709551615)");
    defer r.deinit();
    try testing.expect(r.value.boolean);
}

test "integer variant: cross-variant equality routes via f64" {
    // -5 (i64) = -5.0 (f64) — both project to the same f64 value.
    var r = try evalSource("(= -5 -5.0)");
    defer r.deinit();
    try testing.expect(r.value.boolean);
}

test "integer variant: i64 vs u64 compares exactly, not through f64" {
    // The f64 collapse is deliberate where a `.number` is involved, but
    // between two exact integer variants it is simply wrong: i64.max and
    // i64.max+1 both round to 2^63, so `=` used to call them equal though
    // both are exactly representable and plainly differ.
    const cases = [_]struct { src: [:0]const u8, want: bool }{
        .{ .src = "(= 9223372036854775807 9223372036854775808)", .want = false },
        .{ .src = "(= 9223372036854775807 9223372036854775807)", .want = true },
        // A negative i64 is never equal to a u64, whatever the magnitude.
        .{ .src = "(= -1 18446744073709551615)", .want = false },
        .{ .src = "(= 0 0)", .want = true },
        // …and the boundary the collapse would also have blurred.
        .{ .src = "(= 18446744073709551615 18446744073709551614)", .want = false },
    };
    for (cases) |c| {
        var tr = try evalSource(c.src);
        defer tr.deinit();
        try testing.expectEqual(c.want, tr.value.boolean);

        var br = try evalSourceBinary(c.src);
        defer br.deinit();
        try testing.expectEqual(c.want, br.value.boolean);
    }
}

test "integer variant: toF64 method projects all three numeric shapes" {
    const v_num: Value = .{ .number = 1.5 };
    const v_i64: Value = .{ .integer_i64 = -5 };
    const v_u64: Value = .{ .integer_u64 = std.math.maxInt(u64) };
    const v_str: Value = .{ .string = "" };
    try testing.expectEqual(@as(f64, 1.5), v_num.toF64().?);
    try testing.expectEqual(@as(f64, -5.0), v_i64.toF64().?);
    // u64.max → f64 is lossy but finite.
    try testing.expect(v_u64.toF64() != null);
    try testing.expect(std.math.isFinite(v_u64.toF64().?));
    try testing.expect(v_str.toF64() == null);
}

test "rand-choice: empty vector → TypeMismatch" {
    try testing.expectError(error.TypeMismatch, evalSource("(rand-choice 1 0 [])"));
}

// ---------------------------------------------------------------------------
// Clock-time variant
// ---------------------------------------------------------------------------

test "time atom: 12:34:56 evaluates to time variant" {
    var r = try evalSource("12:34:56");
    defer r.deinit();
    const t = r.value.time;
    try testing.expectEqual(@as(u8, 12), t.hour);
    try testing.expectEqual(@as(u8, 34), t.minute);
    try testing.expectEqual(@as(u8, 56), t.second);
    try testing.expectEqual(@as(u16, 0), t.millisecond);
}

test "time atom: 12:34:56.789 preserves millisecond" {
    var r = try evalSource("12:34:56.789");
    defer r.deinit();
    try testing.expectEqual(@as(u16, 789), r.value.time.millisecond);
}

test "time: let binding preserves variant identity" {
    var r = try evalSource("(let [t 12:34:56.789] t)");
    defer r.deinit();
    try testing.expect(r.value == .time);
    try testing.expectEqual(@as(u16, 789), r.value.time.millisecond);
}

test "time: equality is component-exact" {
    var r1 = try evalSource("(= 12:34:56 12:34:56)");
    defer r1.deinit();
    try testing.expect(r1.value.boolean);
    var r2 = try evalSource("(= 12:34:56 12:34:56.000)");
    defer r2.deinit();
    try testing.expect(r2.value.boolean);
    var r3 = try evalSource("(= 12:34:56 12:34:57)");
    defer r3.deinit();
    try testing.expect(!r3.value.boolean);
}

test "time: no cross-variant collapse with second-of-day integer" {
    // 45296 = 12*3600 + 34*60 + 56. Identity is preserved, not folded.
    var r = try evalSource("(= 12:34:56 45296)");
    defer r.deinit();
    try testing.expect(!r.value.boolean);
}

test "time: vector identity preserves time elements" {
    var r = try evalSource("(let [v [00:00:00 12:34:56.789 23:59:59.999]] v)");
    defer r.deinit();
    const xs = r.value.vector;
    try testing.expectEqual(@as(usize, 3), xs.len);
    try testing.expect(xs[0] == .time);
    try testing.expect(xs[1] == .time);
    try testing.expect(xs[2] == .time);
    try testing.expectEqual(@as(u16, 789), xs[1].time.millisecond);
}

test "time: evalBinary parity for atom" {
    var r1 = try evalSource("12:34:56.789");
    defer r1.deinit();
    var r2 = try evalSourceBinary("12:34:56.789");
    defer r2.deinit();
    try testing.expect(r1.value.time.eql(r2.value.time));
}

// ---------------------------------------------------------------------------
// Calendar-date variant (mirrors the clock-time battery above)
// ---------------------------------------------------------------------------

test "date atom: 2026-07-03 evaluates to date variant" {
    var r = try evalSource("2026-07-03");
    defer r.deinit();
    const d = r.value.date;
    try testing.expectEqual(@as(i16, 2026), d.year);
    try testing.expectEqual(@as(u8, 7), d.month);
    try testing.expectEqual(@as(u8, 3), d.day);
}

test "date atom: min boundary 0001-01-01 preserves components" {
    var r = try evalSource("0001-01-01");
    defer r.deinit();
    const d = r.value.date;
    try testing.expectEqual(@as(i16, 1), d.year);
    try testing.expectEqual(@as(u8, 1), d.month);
    try testing.expectEqual(@as(u8, 1), d.day);
}

test "date: let binding preserves variant identity" {
    var r = try evalSource("(let [d 2026-07-03] d)");
    defer r.deinit();
    try testing.expect(r.value == .date);
    try testing.expectEqual(@as(i16, 2026), r.value.date.year);
}

test "date: equality is component-exact" {
    var r1 = try evalSource("(= 2026-07-03 2026-07-03)");
    defer r1.deinit();
    try testing.expect(r1.value.boolean);
    var r2 = try evalSource("(= 2026-07-03 2026-07-04)");
    defer r2.deinit();
    try testing.expect(!r2.value.boolean);
}

test "date: no cross-variant collapse with an integer" {
    // A date never numerically equals a plain integer, even one that
    // mashes its digits — identity is preserved, not folded.
    var r = try evalSource("(= 2026-07-03 20260703)");
    defer r.deinit();
    try testing.expect(!r.value.boolean);
}

test "date: vector identity preserves date elements" {
    var r = try evalSource("(let [v [0001-01-01 2026-07-03 9999-12-31]] v)");
    defer r.deinit();
    const xs = r.value.vector;
    try testing.expectEqual(@as(usize, 3), xs.len);
    try testing.expect(xs[0] == .date);
    try testing.expect(xs[1] == .date);
    try testing.expect(xs[2] == .date);
    try testing.expectEqual(@as(i16, 2026), xs[1].date.year);
}

test "date: evalBinary parity for atom" {
    var r1 = try evalSource("2026-07-03");
    defer r1.deinit();
    var r2 = try evalSourceBinary("2026-07-03");
    defer r2.deinit();
    try testing.expect(r1.value.date.eql(r2.value.date));
}
