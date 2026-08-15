// GENERATED FILE — do not edit by hand.
//
// Source of truth: src/plugins/core.zig (`expr_funcs`). Regenerate with:
//     zig build gen-expr-ops -- --regen
//
// `zig build test` byte-compares this file against a fresh generation, so
// adding/editing an op in core.zig without regenerating — or hand-editing
// this file — fails CI. Op set, arities, names, and JSDoc mirror the Zig
// table; a curated override map in tools/gen_expr_ops.zig supplies the finer
// types the table can't express (vector tuples, binder forms, generics, and
// the deliberately-opaque polymorphic ops). See tools/gen_expr_ops.zig.
//
// biome ignores this file (biome.json) so its bytes stay authoritative for
// the drift check.

import type { SjonExpr, Symbol_ } from './infer.ts';
import type { SjonValue } from './value.ts';

/** A `T`, or an expr that evaluates to `T`. The composition glue. */
export type ExprLike<T> = T | SjonExpr<T>;
/** A symbol reference to a binding/value — dynamically typed, so it widens any slot. */
export type Ref = Symbol_;
/** Accepted where the core wants a number: literal, numeric expr, or a reference. */
export type NumLike = number | SjonExpr<number> | Ref;
/** Accepted where the core wants a boolean. */
export type BoolLike = boolean | SjonExpr<boolean> | Ref;
/** Accepted where the core wants a vector. */
export type VecLike = readonly number[] | SjonExpr<readonly number[]> | Ref;
/** A binder vector — `[v.sym("x")]` for the higher-order forms. */
export type Binder = readonly Symbol_[];

/** Build `{$expr:[op, ...args]}` with a phantom result type `T`. */
function make<T>(op: string, args: readonly unknown[]): SjonExpr<T> {
  return { $expr: [op, ...args] } as SjonExpr<T>;
}

/** Numeric sum (variadic; (+) → 0). */
export const add = (...xs: NumLike[]): SjonExpr<number> => make('+', xs);

/** Negation (1 arg) or subtraction (2+ args). */
export const sub = (x: NumLike, ...xs: NumLike[]): SjonExpr<number> => make('-', [x, ...xs]);

/** Numeric product (variadic; (*) → 1). */
export const mul = (...xs: NumLike[]): SjonExpr<number> => make('*', xs);

/** Division (left-fold). */
export const div = (a: NumLike, b: NumLike, ...xs: NumLike[]): SjonExpr<number> => make('/', [a, b, ...xs]);

/** Floored remainder; the result takes the divisor's sign (as GLSL mod / Python %). */
export const mod = (x: NumLike, y: NumLike): SjonExpr<number> => make('mod', [x, y]);

export const lt = (a: NumLike, b: NumLike): SjonExpr<boolean> => make('<', [a, b]);

export const gt = (a: NumLike, b: NumLike): SjonExpr<boolean> => make('>', [a, b]);

export const le = (a: NumLike, b: NumLike): SjonExpr<boolean> => make('<=', [a, b]);

export const ge = (a: NumLike, b: NumLike): SjonExpr<boolean> => make('>=', [a, b]);

export const eq = (a: SjonValue, b: SjonValue): SjonExpr<boolean> => make('=', [a, b]);

export const neq = (a: SjonValue, b: SjonValue): SjonExpr<boolean> => make('!=', [a, b]);

/** Short-circuit conjunction; (and) → true. */
export const and = (...xs: SjonValue[]): SjonExpr<boolean> => make('and', xs);

/** Short-circuit disjunction; (or) → false. */
export const or = (...xs: SjonValue[]): SjonExpr<boolean> => make('or', xs);

export const not = (x: BoolLike): SjonExpr<boolean> => make('not', [x]);

/** (let [name expr ...] body) — sequential bindings. */
export const let_ = <T>(bindings: readonly SjonValue[], body: ExprLike<T>): SjonExpr<T> =>
  make('let', [bindings, body]);

export const iff = <T>(test: BoolLike, then: ExprLike<T>, otherwise?: ExprLike<T>): SjonExpr<T> =>
  make('if', otherwise === undefined ? [test, then] : [test, then, otherwise]);

/** (cond test1 expr1 test2 expr2 …). */
export const cond = (...xs: SjonValue[]): SjonExpr<unknown> => make('cond', xs);

/** (map [x] xs body) — vector of body values, one per element. */
export const map = (binder: Binder, xs: VecLike, body: SjonValue): SjonExpr<readonly unknown[]> =>
  make('map', [binder, xs, body]);

/** (filter [x] xs pred) — vector of original elements where pred is truthy. */
export const filter = (binder: Binder, xs: VecLike, pred: SjonValue): SjonExpr<readonly unknown[]> =>
  make('filter', [binder, xs, pred]);

/** (any [x] xs pred) — true if pred is truthy for some element; short-circuits. */
export const any = (binder: Binder, xs: VecLike, pred: SjonValue): SjonExpr<boolean> =>
  make('any', [binder, xs, pred]);

/** (all [x] xs pred) — true if pred is truthy for every element; short-circuits. */
export const all = (binder: Binder, xs: VecLike, pred: SjonValue): SjonExpr<boolean> =>
  make('all', [binder, xs, pred]);

/** (fold [acc x] init xs body) — left-fold; threads body's result as next iteration's acc; returns init on empty xs. */
export const fold = (binder: Binder, init: SjonValue, xs: VecLike, body: SjonValue): SjonExpr<unknown> =>
  make('fold', [binder, init, xs, body]);

export const vec2 = (x: NumLike, y: NumLike): SjonExpr<readonly [number, number]> =>
  make('vec2', [x, y]);

export const vec3 = (x: NumLike, y: NumLike, z: NumLike): SjonExpr<readonly [number, number, number]> =>
  make('vec3', [x, y, z]);

export const vec4 = (x: NumLike, y: NumLike, z: NumLike, w: NumLike): SjonExpr<readonly [number, number, number, number]> =>
  make('vec4', [x, y, z, w]);

/** (lerp from to t) — linear interpolation. */
export const lerp = (from: NumLike, to: NumLike, t: NumLike): SjonExpr<number> =>
  make('lerp', [from, to, t]);

/** (clamp x lo hi). */
export const clamp = (x: NumLike, lo: NumLike, hi: NumLike): SjonExpr<number> =>
  make('clamp', [x, lo, hi]);

export const min = (x: NumLike, ...xs: NumLike[]): SjonExpr<number> => make('min', [x, ...xs]);

export const max = (x: NumLike, ...xs: NumLike[]): SjonExpr<number> => make('max', [x, ...xs]);

export const dot = (a: VecLike, b: VecLike): SjonExpr<number> => make('dot', [a, b]);

export const cross = (a: VecLike, b: VecLike): SjonExpr<readonly number[]> => make('cross', [a, b]);

export const length = (v: VecLike): SjonExpr<number> => make('length', [v]);

/** Absolute value. */
export const abs = (x: NumLike): SjonExpr<number> => make('abs', [x]);

/** Sign: -1, 0, or 1; NaN passthrough. */
export const sign = (x: NumLike): SjonExpr<number> => make('sign', [x]);

export const floor = (x: NumLike): SjonExpr<number> => make('floor', [x]);

export const ceil = (x: NumLike): SjonExpr<number> => make('ceil', [x]);

/** Round half away from zero. */
export const round = (x: NumLike): SjonExpr<number> => make('round', [x]);

/** x − floor(x); WGSL — result may be exactly 1.0. */
export const fract = (x: NumLike): SjonExpr<number> => make('fract', [x]);

/** Principal square root; (sqrt x<0) → NaN. */
export const sqrt = (x: NumLike): SjonExpr<number> => make('sqrt', [x]);

/** (pow base exp). */
export const pow = (base: NumLike, exp: NumLike): SjonExpr<number> => make('pow', [base, exp]);

/** Sine of x in radians. */
export const sin = (x: NumLike): SjonExpr<number> => make('sin', [x]);

/** Cosine of x in radians. */
export const cos = (x: NumLike): SjonExpr<number> => make('cos', [x]);

/** Tangent of x in radians. */
export const tan = (x: NumLike): SjonExpr<number> => make('tan', [x]);

/** Arcsine; |x|>1 → NaN. */
export const asin = (x: NumLike): SjonExpr<number> => make('asin', [x]);

/** Arccosine; |x|>1 → NaN. */
export const acos = (x: NumLike): SjonExpr<number> => make('acos', [x]);

/** Arctangent (1-arg). */
export const atan = (x: NumLike): SjonExpr<number> => make('atan', [x]);

/** (atan2 y x) — angle of (x, y) in [-π, π]. */
export const atan2 = (y: NumLike, x: NumLike): SjonExpr<number> => make('atan2', [y, x]);

/** Degrees → radians. */
export const radians = (x: NumLike): SjonExpr<number> => make('radians', [x]);

/** Radians → degrees. */
export const degrees = (x: NumLike): SjonExpr<number> => make('degrees', [x]);

/** (pi) → 3.141592653589793. */
export const pi = (): SjonExpr<number> => make('pi', []);

/** (tau) → 2π. */
export const tau = (): SjonExpr<number> => make('tau', []);

/** clamp(x, 0, 1). */
export const saturate = (x: NumLike): SjonExpr<number> => make('saturate', [x]);

/** (step edge x) → 0 if x<edge else 1. */
export const step = (edge: NumLike, x: NumLike): SjonExpr<number> => make('step', [edge, x]);

/** (smoothstep low high x); WGSL — low==high is indeterminate. */
export const smoothstep = (low: NumLike, high: NumLike, x: NumLike): SjonExpr<number> => make('smoothstep', [low, high, x]);

/** Unit vector; zero or empty → error. */
export const normalize = (x: VecLike): SjonExpr<readonly number[]> => make('normalize', [x]);

/** Euclidean distance; lengths must match. */
export const distance = (a: VecLike, b: VecLike): SjonExpr<number> => make('distance', [a, b]);

/** (reflect I N); N must be unit-length (caller's responsibility). */
export const reflect = (i: VecLike, n: VecLike): SjonExpr<readonly number[]> => make('reflect', [i, n]);

/** (nth v i) — 0-indexed; OOB or non-integer i → error. */
export const nth = (v: VecLike, i: NumLike): SjonExpr<unknown> => make('nth', [v, i]);

/** Number of elements in a vector. */
export const count = (x: VecLike): SjonExpr<number> => make('count', [x]);

/** (hash seed key) → 53-bit integer-as-f64 in [0, 2^53). */
export const hash = (seed: NumLike, key: NumLike): SjonExpr<number> => make('hash', [seed, key]);

/** (rand01 seed key) → uniform float in [0, 1). */
export const rand01 = (seed: NumLike, key: NumLike): SjonExpr<number> => make('rand01', [seed, key]);

/** (rand-range seed key lo hi) → uniform float in [lo, hi). */
export const randRange = (seed: NumLike, key: NumLike, lo: NumLike, hi: NumLike): SjonExpr<number> => make('rand-range', [seed, key, lo, hi]);

/** (rand-int seed key lo hi) → uniform integer in [lo, hi]. */
export const randInt = (seed: NumLike, key: NumLike, lo: NumLike, hi: NumLike): SjonExpr<number> => make('rand-int', [seed, key, lo, hi]);

/** (rand-bool seed key p) → true with probability clamp(p, 0, 1). */
export const randBool = (seed: NumLike, key: NumLike, p: NumLike): SjonExpr<boolean> => make('rand-bool', [seed, key, p]);

/** (rand-choice seed key v) — pick an element; empty v → error. */
export const randChoice = (seed: NumLike, key: NumLike, v: VecLike): SjonExpr<unknown> => make('rand-choice', [seed, key, v]);

/**
 * Build an arbitrary `(head …args)` expr — for a plugin op outside the curated
 * core set. Untyped (`SjonExpr<unknown>`, no arity check): prefer a named `e.*`
 * when one exists.
 */
export const call = (head: string, ...args: unknown[]): SjonExpr<unknown> => make(head, args);
