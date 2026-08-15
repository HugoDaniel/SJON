// Internal utility for the parity host — a compile-time exhaustiveness guard.
// Package-root so both the schema exporter and patternQuery share one copy;
// not re-exported (no `src/index.ts`). Mirrors `@sjon/schema`'s `assertNever`.

/**
 * Compile-time exhaustiveness: ending a `switch` over a discriminated union
 * with `default: return assertNever(x)` makes a new, unhandled variant a type
 * error — it is no longer assignable to the `never` parameter, so the call
 * fails to compile and points at the switch that forgot it. The runtime throw
 * is only a backstop for a value forged past the types.
 */
export function assertNever(x: never): never {
  throw new Error(`sjon-parity: unhandled variant ${JSON.stringify(x)}`);
}

/**
 * Inferred type guard: narrows an `unknown` to a plain object map,
 * excluding `null` and arrays. Preferred to an inline
 * `typeof x === 'object' && x !== null` + `as Record` cast — it narrows,
 * so a following `x['key']` needs no cast. Mirrors `@sjon/schema`'s
 * `isRecord`.
 */
export function isRecord(x: unknown): x is Record<string, unknown> {
  return x !== null && typeof x === 'object' && !Array.isArray(x);
}
