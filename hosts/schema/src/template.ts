// Tagged template — `sjon\`…\`` produces SJON *text* with typed,
// serialize-by-type holes. This is the deliberately-limited "tagged template"
// approach (the user's `` sx`(+ 1 ${x})` ``), kept as an *escape hatch*, not
// the core surface. A *parsing* template was rejected: it would
// re-implement a front-end we already own, and a parse result is opaque
// to TS anyway.
//
// What makes this variant safe and worthwhile:
//   * It produces text, runs no parser → works on every backend.
//   * Each `${hole}` is a typed `SjonValue` rendered by `serializeValue`, so a
//     string hole becomes a *quoted token* — it cannot inject structure or
//     break out of the surrounding form. The literal text between holes is the
//     author's own and is emitted verbatim (that is where free-form SJON
//     syntax lives).
//   * It composes: a hole can be an `e.*` expr, a `v.*` atom, or a
//     `Form.create(...)` value, and `Form.parse(sjon\`…\`)` materialises it on
//     a WASM backend.

import { serializeValue } from './value.ts';
import type { SjonValue } from './value.ts';

/**
 * Assemble SJON text, serializing each interpolated value by its type.
 *
 * ```ts
 * sjon`(point :x ${1} :y ${2})`            // (point :x 1 :y 2)
 * sjon`(label ${"a) (evil"})`              // (label "a) (evil")  — hole can't escape
 * sjon`(size ${e.mul(2, v.sym("w"))})`     // (size (* 2 w))
 * ```
 */
export function sjon(strings: TemplateStringsArray, ...holes: SjonValue[]): string {
  let out = strings[0] ?? '';
  for (let i = 0; i < holes.length; i++) {
    out += serializeValue(holes[i]!) + (strings[i + 1] ?? '');
  }
  return out;
}
