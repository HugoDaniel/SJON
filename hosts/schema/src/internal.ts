// Internal utilities — deliberately NOT part of the public `@sjon/schema`
// surface (`index.ts` never re-exports this module). Small, zero-dependency
// helpers the builder and serializer share.

/**
 * Compile-time exhaustiveness guard. In a `switch` over a discriminated
 * union, ending with `default: return assertNever(x)` makes adding an
 * unhandled variant a *type* error — the new variant is no longer assignable
 * to the `never` parameter, so the call fails to compile and points at the
 * switch that forgot it. The runtime `throw` is only a backstop for a value
 * forged past the type system (e.g. cast through `unknown`).
 */
export function assertNever(x: never): never {
  throw new Error(`SJON schema: unhandled variant ${JSON.stringify(x)}`);
}

/**
 * Narrow an `unknown` to a plain (non-null, non-array) object. The inferred
 * `x is Record<string, unknown>` predicate replaces the open-coded
 * `x !== null && typeof x === 'object' && !Array.isArray(x)` probe at every
 * call site — real narrowing instead of a bare boolean, so a following
 * `x['$form']` needs no cast.
 */
export function isRecord(x: unknown): x is Record<string, unknown> {
  return x !== null && typeof x === 'object' && !Array.isArray(x);
}

/** An {@link isRecord} that additionally carries a `$form` discriminator. */
export function isFormObject(x: unknown): x is Record<string, unknown> {
  return isRecord(x) && '$form' in x;
}
