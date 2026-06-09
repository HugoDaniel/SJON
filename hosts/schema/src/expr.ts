// Typed `e.*` expression constructors for SJON expression values.
//
// The constructor surface is GENERATED from src/plugins/core.zig's `expr_funcs`
// table (the single source of truth) into ./expr.gen.ts by tools/gen_expr_ops.zig.
// This module re-exports it so `@sjon/schema`'s public `e` namespace and the
// shared arg-type aliases (NumLike, BoolLike, VecLike, Binder, …) keep a stable
// import path while the op set tracks the Zig core 1:1 (a drift check in
// `zig build test` fails CI if they diverge — regenerate with
// `zig build gen-expr-ops -- --regen`).
//
// On top of the generated surface this module adds **closure-binder sugar** for
// the higher-order forms: `e.map(xs, x => …)` instead of the first-order
// `e.map([v.sym("x")], xs, …)`. These are pure build-time desugaring — the arrow
// runs once, with a freshly-minted symbol bound to its parameter, and we emit the
// exact same first-order AST. No runtime closures, no new Value variant. A local
// re-declaration shadows the generated export (`export *` omits names declared
// locally here), and the explicit-binder overload stays as the escape hatch.

import {
  all as allBase,
  any as anyBase,
  filter as filterBase,
  fold as foldBase,
  map as mapBase,
} from './expr.gen.ts';
import type { Binder, Ref, VecLike } from './expr.gen.ts';
import type { SjonExpr } from './infer.ts';
import type { SjonValue } from './value.ts';

export * from './expr.gen.ts';

// Monotonic counter (not Math.random / Date — deterministic build output). Each
// `gensym` mints a reserved-prefix symbol: `_` is a legal SJON symbol head
// (Lexer.zig symbol-head set), so `__sjon_b<n>` lexes as a plain symbol, and the
// `__sjon_b` prefix won't collide with author-chosen binder names. Distinct per
// call, so nested `e.map(xs, x => e.map(ys, y => …))` never reuse a name.
let binderCounter = 0;
function gensym(): Ref {
  return { $sym: `__sjon_b${binderCounter++}` } as Ref;
}

/**
 * `(map [x] xs body)` — vector of body values, one per element.
 *
 * Two call forms: the explicit binder `e.map([v.sym("x")], xs, body)`, or the
 * arrow sugar `e.map(xs, x => body)` where `x` is a fresh symbol reference
 * (usable anywhere a `NumLike` / `VecLike` / … is wanted).
 */
export function map(binder: Binder, xs: VecLike, body: SjonValue): SjonExpr<readonly unknown[]>;
export function map(xs: VecLike, fn: (x: Ref) => SjonValue): SjonExpr<readonly unknown[]>;
export function map(
  a: Binder | VecLike,
  b: VecLike | ((x: Ref) => SjonValue),
  body?: SjonValue,
): SjonExpr<readonly unknown[]> {
  if (typeof b === 'function') {
    const x = gensym();
    return mapBase([x], a as VecLike, b(x));
  }
  return mapBase(a as Binder, b as VecLike, body as SjonValue);
}

/** `(filter [x] xs pred)` — elements where pred is truthy. Arrow sugar: `e.filter(xs, x => pred)`. */
export function filter(binder: Binder, xs: VecLike, pred: SjonValue): SjonExpr<readonly unknown[]>;
export function filter(xs: VecLike, fn: (x: Ref) => SjonValue): SjonExpr<readonly unknown[]>;
export function filter(
  a: Binder | VecLike,
  b: VecLike | ((x: Ref) => SjonValue),
  pred?: SjonValue,
): SjonExpr<readonly unknown[]> {
  if (typeof b === 'function') {
    const x = gensym();
    return filterBase([x], a as VecLike, b(x));
  }
  return filterBase(a as Binder, b as VecLike, pred as SjonValue);
}

/** `(any [x] xs pred)` — true if pred is truthy for some element. Arrow sugar: `e.any(xs, x => pred)`. */
export function any(binder: Binder, xs: VecLike, pred: SjonValue): SjonExpr<boolean>;
export function any(xs: VecLike, fn: (x: Ref) => SjonValue): SjonExpr<boolean>;
export function any(
  a: Binder | VecLike,
  b: VecLike | ((x: Ref) => SjonValue),
  pred?: SjonValue,
): SjonExpr<boolean> {
  if (typeof b === 'function') {
    const x = gensym();
    return anyBase([x], a as VecLike, b(x));
  }
  return anyBase(a as Binder, b as VecLike, pred as SjonValue);
}

/** `(all [x] xs pred)` — true if pred is truthy for every element. Arrow sugar: `e.all(xs, x => pred)`. */
export function all(binder: Binder, xs: VecLike, pred: SjonValue): SjonExpr<boolean>;
export function all(xs: VecLike, fn: (x: Ref) => SjonValue): SjonExpr<boolean>;
export function all(
  a: Binder | VecLike,
  b: VecLike | ((x: Ref) => SjonValue),
  pred?: SjonValue,
): SjonExpr<boolean> {
  if (typeof b === 'function') {
    const x = gensym();
    return allBase([x], a as VecLike, b(x));
  }
  return allBase(a as Binder, b as VecLike, pred as SjonValue);
}

/**
 * `(fold [acc x] init xs body)` — left-fold; threads body's result as next acc.
 *
 * Explicit: `e.fold([v.sym("acc"), v.sym("x")], init, xs, body)`. Arrow sugar:
 * `e.fold(init, xs, (acc, x) => body)` with fresh `acc` / `x` symbol references.
 */
export function fold(
  binder: Binder,
  init: SjonValue,
  xs: VecLike,
  body: SjonValue,
): SjonExpr<unknown>;
export function fold(
  init: SjonValue,
  xs: VecLike,
  fn: (acc: Ref, x: Ref) => SjonValue,
): SjonExpr<unknown>;
export function fold(
  a: Binder | SjonValue,
  b: SjonValue | VecLike,
  c: VecLike | ((acc: Ref, x: Ref) => SjonValue),
  body?: SjonValue,
): SjonExpr<unknown> {
  if (typeof c === 'function') {
    const acc = gensym();
    const x = gensym();
    return foldBase([acc, x], a as SjonValue, b as VecLike, c(acc, x));
  }
  return foldBase(a as Binder, b as SjonValue, c as VecLike, body as SjonValue);
}
