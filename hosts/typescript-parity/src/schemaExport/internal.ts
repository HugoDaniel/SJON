// Internal utility for the schema exporter — a compile-time exhaustiveness
// guard. Local to this directory (the parity host has no shared util module);
// mirrors `@sjon/schema`'s `assertNever`.

/**
 * Compile-time exhaustiveness: ending a `switch` over a discriminated union
 * with `default: return assertNever(x)` makes a new, unhandled variant a type
 * error — it is no longer assignable to the `never` parameter, so the call
 * fails to compile and points at the switch that forgot it. The runtime throw
 * is only a backstop for a value forged past the types.
 */
export function assertNever(x: never): never {
  throw new Error(`sjon schema-export: unhandled variant ${JSON.stringify(x)}`);
}
