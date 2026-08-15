//! Built-in `core` plugin — the closed v1 expression vocabulary.
//!
//! Ships only `expr_funcs`. No data forms, no value kinds — domains live
//! in downstream plugins (PNGine, masagin, …) outside this repo.
//!
//! Each entry's `.impl` plugs `Expr.applyXxx` into the evaluator vtable.
//! Control-flow funcs (`let` / `if` / `cond` / `and` / `or`) leave
//! `.impl = null` because they're handled by dedicated frames in the
//! evaluator, not by `applyFunction`.

const std = @import("std");
const Plugin = @import("../Plugin.zig");
const Expr = @import("../Expr.zig");

/// The built-in `core` plugin. Pass it (alongside any domain plugins) to
/// `Schema.init`. v0.1 ships only `core`; downstream plugins (PNGine,
/// masagin, …) live in their own repos.
pub const plugin: Plugin.Plugin = .{
    .name = "core",
    .expr_funcs = &expr_funcs,
};

const at_least_one: Plugin.ExprFunc.Arity = .{ .at_least = 1 };
const at_least_two: Plugin.ExprFunc.Arity = .{ .at_least = 2 };

const number_pair: [2]Plugin.ValueType = .{ .number, .number };
const single_number: [1]Plugin.ValueType = .{.number};
const single_boolean: [1]Plugin.ValueType = .{.boolean};
const single_vector: [1]Plugin.ValueType = .{.vector};
const triple_number: [3]Plugin.ValueType = .{ .number, .number, .number };
const quad_number: [4]Plugin.ValueType = .{ .number, .number, .number, .number };
const vector_pair: [2]Plugin.ValueType = .{ .vector, .vector };
const vector_and_number: [2]Plugin.ValueType = .{ .vector, .number };
// Random funcs: (seed key …). All seeds and keys are numbers.
const rand2_params: [2]Plugin.ValueType = .{ .number, .number };
const rand_range_params: [4]Plugin.ValueType = .{ .number, .number, .number, .number };
const rand_bool_params: [3]Plugin.ValueType = .{ .number, .number, .number };
const rand_choice_params: [3]Plugin.ValueType = .{ .number, .number, .vector };

// Parameter names for opt-in labeled call form (Swift-style). Names
// match WGSL conventions for graphics intrinsics where applicable
// (`step(edge, x)`, `smoothstep(low, high, x)`, `reflect(I, N)`).
const names_xy: [2][]const u8 = .{ "x", "y" };
const names_ab: [2][]const u8 = .{ "a", "b" };
const names_in: [2][]const u8 = .{ "i", "n" };
const names_vi: [2][]const u8 = .{ "v", "i" };
const names_pow: [2][]const u8 = .{ "base", "exp" };
const names_atan2: [2][]const u8 = .{ "y", "x" };
const names_step: [2][]const u8 = .{ "edge", "x" };
const names_seed_key: [2][]const u8 = .{ "seed", "key" };
const names_xyz: [3][]const u8 = .{ "x", "y", "z" };
const names_xyzw: [4][]const u8 = .{ "x", "y", "z", "w" };
const names_lerp: [3][]const u8 = .{ "from", "to", "t" };
const names_clamp: [3][]const u8 = .{ "x", "lo", "hi" };
const names_smoothstep: [3][]const u8 = .{ "low", "high", "x" };
const names_rand_bool: [3][]const u8 = .{ "seed", "key", "p" };
const names_rand_choice: [3][]const u8 = .{ "seed", "key", "v" };
const names_rand_range: [4][]const u8 = .{ "seed", "key", "lo", "hi" };

/// The complete v1 expression vocabulary, in declaration order. Each
/// entry's `.name` matches the symbol used in source (e.g. `+`, `lerp`,
/// `vec3`).
///
/// Typed signature notes (`params`/`rest`/`result`):
///   * Arithmetic / comparison / vector funcs carry typed signatures —
///     `(+ 1 "x")` and `(< "a" 1)` are now caught at validate-time.
///   * Polymorphic funcs (`=`, `!=`, `lerp`, `clamp`, `min`, `max`,
///     `dot`, `cross`, `length`) are left opaque pending overload
///     support.
///   * Lazy / control-flow funcs (`and`, `or`, `let`, `if`, `cond`)
///     are opaque by design — their typing depends on bound values
///     or branch evaluation, which the validator cannot statically
///     resolve.
pub const expr_funcs = [_]Plugin.ExprFunc{
    // -- Arithmetic ---------------------------------------------------------
    .{ .name = "+", .arity = .{ .at_least = 0 }, .impl = &Expr.applySum, .rest = .number, .result = .number, .description = "Numeric sum (variadic; (+) → 0)." },
    .{ .name = "-", .arity = at_least_one, .impl = &Expr.applyDiff, .params = &single_number, .rest = .number, .result = .number, .description = "Negation (1 arg) or subtraction (2+ args)." },
    .{ .name = "*", .arity = .{ .at_least = 0 }, .impl = &Expr.applyProduct, .rest = .number, .result = .number, .description = "Numeric product (variadic; (*) → 1)." },
    .{ .name = "/", .arity = at_least_two, .impl = &Expr.applyQuotient, .params = &single_number, .rest = .number, .result = .number, .description = "Division (left-fold)." },
    .{ .name = "mod", .arity = .{ .fixed = 2 }, .impl = &Expr.applyMod, .params = &number_pair, .param_names = &names_xy, .result = .number, .description = "Floored remainder; the result takes the divisor's sign (as GLSL mod / Python %)." },

    // -- Comparison (binary) -----------------------------------------------
    .{ .name = "<", .arity = .{ .fixed = 2 }, .impl = &Expr.applyLt, .params = &number_pair, .result = .boolean },
    .{ .name = ">", .arity = .{ .fixed = 2 }, .impl = &Expr.applyGt, .params = &number_pair, .result = .boolean },
    .{ .name = "<=", .arity = .{ .fixed = 2 }, .impl = &Expr.applyLe, .params = &number_pair, .result = .boolean },
    .{ .name = ">=", .arity = .{ .fixed = 2 }, .impl = &Expr.applyGe, .params = &number_pair, .result = .boolean },
    // `=` / `!=` are polymorphic — leave args opaque pending overload support.
    .{ .name = "=", .arity = .{ .fixed = 2 }, .impl = &Expr.applyEq, .result = .boolean },
    .{ .name = "!=", .arity = .{ .fixed = 2 }, .impl = &Expr.applyNeq, .result = .boolean },

    // -- Logical -----------------------------------------------------------
    // `and` / `or` are short-circuiting — handled by dedicated frames.
    // Args are opaque (any truthy value); result is boolean.
    .{ .name = "and", .arity = .{ .at_least = 0 }, .result = .boolean, .description = "Short-circuit conjunction; (and) → true." },
    .{ .name = "or", .arity = .{ .at_least = 0 }, .result = .boolean, .description = "Short-circuit disjunction; (or) → false." },
    .{ .name = "not", .arity = .{ .fixed = 1 }, .impl = &Expr.applyNot, .params = &single_boolean, .result = .boolean },

    // -- Binding / control ------------------------------------------------
    // All three need lazy evaluation — handled by dedicated frames. Their
    // signatures are opaque: `let` typing depends on bindings, `if`/`cond`
    // on branch evaluation. Validator enforces arity only.
    .{ .name = "let", .arity = .{ .fixed = 2 }, .description = "(let [name expr ...] body) — sequential bindings." },
    .{ .name = "if", .arity = .{ .range = .{ .min = 2, .max = 3 } } },
    .{ .name = "cond", .arity = .{ .at_least = 0 }, .description = "(cond test1 expr1 test2 expr2 …)." },

    // -- Higher-order binder forms ----------------------------------------
    // Each binds the symbol in `[name]` to xs[i] while evaluating body /
    // pred once per element. Dispatched through dedicated evaluator
    // frames (not `applyFunction`); signatures are opaque because the
    // body's result type depends on the body's evaluation.
    .{ .name = "map", .arity = .{ .fixed = 3 }, .result = .vector, .description = "(map [x] xs body) — vector of body values, one per element." },
    .{ .name = "filter", .arity = .{ .fixed = 3 }, .result = .vector, .description = "(filter [x] xs pred) — vector of original elements where pred is truthy." },
    .{ .name = "any", .arity = .{ .fixed = 3 }, .result = .boolean, .description = "(any [x] xs pred) — true if pred is truthy for some element; short-circuits." },
    .{ .name = "all", .arity = .{ .fixed = 3 }, .result = .boolean, .description = "(all [x] xs pred) — true if pred is truthy for every element; short-circuits." },
    .{ .name = "fold", .arity = .{ .fixed = 4 }, .description = "(fold [acc x] init xs body) — left-fold; threads body's result as next iteration's acc; returns init on empty xs." },

    // -- Vectors ----------------------------------------------------------
    .{ .name = "vec2", .arity = .{ .fixed = 2 }, .impl = &Expr.applyVec2, .params = &number_pair, .param_names = &names_xy, .result = .vector },
    .{ .name = "vec3", .arity = .{ .fixed = 3 }, .impl = &Expr.applyVec3, .params = &triple_number, .param_names = &names_xyz, .result = .vector },
    .{ .name = "vec4", .arity = .{ .fixed = 4 }, .impl = &Expr.applyVec4, .params = &quad_number, .param_names = &names_xyzw, .result = .vector },

    // -- Math --------------------------------------------------------------
    // Polymorphic — left opaque pending overload support. `param_names`
    // is set for opt-in labeled calls; types remain unconstrained.
    .{ .name = "lerp", .arity = .{ .fixed = 3 }, .impl = &Expr.applyLerp, .param_names = &names_lerp, .description = "(lerp from to t) — linear interpolation." },
    .{ .name = "clamp", .arity = .{ .fixed = 3 }, .impl = &Expr.applyClamp, .param_names = &names_clamp, .description = "(clamp x lo hi)." },
    .{ .name = "min", .arity = at_least_one, .impl = &Expr.applyMin },
    .{ .name = "max", .arity = at_least_one, .impl = &Expr.applyMax },
    .{ .name = "dot", .arity = .{ .fixed = 2 }, .impl = &Expr.applyDot, .param_names = &names_ab },
    .{ .name = "cross", .arity = .{ .fixed = 2 }, .impl = &Expr.applyCross, .param_names = &names_ab },
    .{ .name = "length", .arity = .{ .fixed = 1 }, .impl = &Expr.applyLength },

    // -- Math (extended) ---------------------------------------------------
    // Scalar f64 → f64. Domain errors propagate IEEE 754 NaN.
    .{ .name = "abs", .arity = .{ .fixed = 1 }, .impl = &Expr.applyAbs, .params = &single_number, .result = .number, .description = "Absolute value." },
    .{ .name = "sign", .arity = .{ .fixed = 1 }, .impl = &Expr.applySign, .params = &single_number, .result = .number, .description = "Sign: -1, 0, or 1; NaN passthrough." },
    .{ .name = "floor", .arity = .{ .fixed = 1 }, .impl = &Expr.applyFloor, .params = &single_number, .result = .number },
    .{ .name = "ceil", .arity = .{ .fixed = 1 }, .impl = &Expr.applyCeil, .params = &single_number, .result = .number },
    .{ .name = "round", .arity = .{ .fixed = 1 }, .impl = &Expr.applyRound, .params = &single_number, .result = .number, .description = "Round half away from zero." },
    .{ .name = "fract", .arity = .{ .fixed = 1 }, .impl = &Expr.applyFract, .params = &single_number, .result = .number, .description = "x − floor(x); WGSL — result may be exactly 1.0." },
    .{ .name = "sqrt", .arity = .{ .fixed = 1 }, .impl = &Expr.applySqrt, .params = &single_number, .result = .number, .description = "Principal square root; (sqrt x<0) → NaN." },
    .{ .name = "pow", .arity = .{ .fixed = 2 }, .impl = &Expr.applyPow, .params = &number_pair, .param_names = &names_pow, .result = .number, .description = "(pow base exp)." },
    .{ .name = "sin", .arity = .{ .fixed = 1 }, .impl = &Expr.applySin, .params = &single_number, .result = .number, .description = "Sine of x in radians." },
    .{ .name = "cos", .arity = .{ .fixed = 1 }, .impl = &Expr.applyCos, .params = &single_number, .result = .number, .description = "Cosine of x in radians." },
    .{ .name = "tan", .arity = .{ .fixed = 1 }, .impl = &Expr.applyTan, .params = &single_number, .result = .number, .description = "Tangent of x in radians." },
    .{ .name = "asin", .arity = .{ .fixed = 1 }, .impl = &Expr.applyAsin, .params = &single_number, .result = .number, .description = "Arcsine; |x|>1 → NaN." },
    .{ .name = "acos", .arity = .{ .fixed = 1 }, .impl = &Expr.applyAcos, .params = &single_number, .result = .number, .description = "Arccosine; |x|>1 → NaN." },
    .{ .name = "atan", .arity = .{ .fixed = 1 }, .impl = &Expr.applyAtan, .params = &single_number, .result = .number, .description = "Arctangent (1-arg)." },
    .{ .name = "atan2", .arity = .{ .fixed = 2 }, .impl = &Expr.applyAtan2, .params = &number_pair, .param_names = &names_atan2, .result = .number, .description = "(atan2 y x) — angle of (x, y) in [-π, π]." },
    .{ .name = "radians", .arity = .{ .fixed = 1 }, .impl = &Expr.applyRadians, .params = &single_number, .result = .number, .description = "Degrees → radians." },
    .{ .name = "degrees", .arity = .{ .fixed = 1 }, .impl = &Expr.applyDegrees, .params = &single_number, .result = .number, .description = "Radians → degrees." },

    // -- Constants (0-arity) -----------------------------------------------
    .{ .name = "pi", .arity = .{ .fixed = 0 }, .impl = &Expr.applyPi, .result = .number, .description = "(pi) → 3.141592653589793." },
    .{ .name = "tau", .arity = .{ .fixed = 0 }, .impl = &Expr.applyTau, .result = .number, .description = "(tau) → 2π." },

    // -- Smoothing (WGSL conventions) -------------------------------------
    .{ .name = "saturate", .arity = .{ .fixed = 1 }, .impl = &Expr.applySaturate, .params = &single_number, .result = .number, .description = "clamp(x, 0, 1)." },
    .{ .name = "step", .arity = .{ .fixed = 2 }, .impl = &Expr.applyStep, .params = &number_pair, .param_names = &names_step, .result = .number, .description = "(step edge x) → 0 if x<edge else 1." },
    .{ .name = "smoothstep", .arity = .{ .fixed = 3 }, .impl = &Expr.applySmoothstep, .params = &triple_number, .param_names = &names_smoothstep, .result = .number, .description = "(smoothstep low high x); WGSL — low==high is indeterminate." },

    // -- Vector ops (extended) -------------------------------------------
    .{ .name = "normalize", .arity = .{ .fixed = 1 }, .impl = &Expr.applyNormalize, .params = &single_vector, .result = .vector, .description = "Unit vector; zero or empty → error." },
    .{ .name = "distance", .arity = .{ .fixed = 2 }, .impl = &Expr.applyDistance, .params = &vector_pair, .param_names = &names_ab, .result = .number, .description = "Euclidean distance; lengths must match." },
    .{ .name = "reflect", .arity = .{ .fixed = 2 }, .impl = &Expr.applyReflect, .params = &vector_pair, .param_names = &names_in, .result = .vector, .description = "(reflect I N); N must be unit-length (caller's responsibility)." },

    // -- List ops ---------------------------------------------------------
    .{ .name = "nth", .arity = .{ .fixed = 2 }, .impl = &Expr.applyNth, .params = &vector_and_number, .param_names = &names_vi, .description = "(nth v i) — 0-indexed; OOB or non-integer i → error." },
    .{ .name = "count", .arity = .{ .fixed = 1 }, .impl = &Expr.applyCount, .params = &single_vector, .result = .number, .description = "Number of elements in a vector." },

    // -- Seeded random (deterministic SplitMix64) ------------------------
    // All randoms take (seed key …) and are pure functions of their args.
    // Same inputs → same outputs across platforms and Zig versions.
    .{ .name = "hash", .arity = .{ .fixed = 2 }, .impl = &Expr.applyHash, .params = &rand2_params, .param_names = &names_seed_key, .result = .number, .description = "(hash seed key) → 53-bit integer-as-f64 in [0, 2^53)." },
    .{ .name = "rand01", .arity = .{ .fixed = 2 }, .impl = &Expr.applyRand01, .params = &rand2_params, .param_names = &names_seed_key, .result = .number, .description = "(rand01 seed key) → uniform float in [0, 1)." },
    .{ .name = "rand-range", .arity = .{ .fixed = 4 }, .impl = &Expr.applyRandRange, .params = &rand_range_params, .param_names = &names_rand_range, .result = .number, .description = "(rand-range seed key lo hi) → uniform float in [lo, hi)." },
    .{ .name = "rand-int", .arity = .{ .fixed = 4 }, .impl = &Expr.applyRandInt, .params = &rand_range_params, .param_names = &names_rand_range, .result = .number, .description = "(rand-int seed key lo hi) → uniform integer in [lo, hi]." },
    .{ .name = "rand-bool", .arity = .{ .fixed = 3 }, .impl = &Expr.applyRandBool, .params = &rand_bool_params, .param_names = &names_rand_bool, .result = .boolean, .description = "(rand-bool seed key p) → true with probability clamp(p, 0, 1)." },
    .{ .name = "rand-choice", .arity = .{ .fixed = 3 }, .impl = &Expr.applyRandChoice, .params = &rand_choice_params, .param_names = &names_rand_choice, .description = "(rand-choice seed key v) — pick an element; empty v → error." },
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "core plugin name" {
    try testing.expectEqualStrings("core", plugin.name);
}

test "core has the expected vocabulary size" {
    // Sanity check — fail loud if we accidentally drop or duplicate funcs.
    // Bumped after the v0.2 stdlib expansion (~32 new built-ins).
    try testing.expect(plugin.expr_funcs.len > 50);
    try testing.expect(plugin.expr_funcs.len < 80);
}

test "core: vec3 has fixed arity 3" {
    var found: bool = false;
    for (plugin.expr_funcs) |f| {
        if (std.mem.eql(u8, f.name, "vec3")) {
            try testing.expectEqual(@as(u8, 3), f.arity.fixed);
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "core: + accepts zero or more args" {
    for (plugin.expr_funcs) |f| {
        if (std.mem.eql(u8, f.name, "+")) {
            try testing.expect(f.checkArity(0));
            try testing.expect(f.checkArity(5));
            return;
        }
    }
    try testing.expect(false);
}
