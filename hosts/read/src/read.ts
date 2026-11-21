// The two public entry policies and the re-exported `fields` view.
//
// `read` is exactly `readResult` followed by one err-severity check: it never
// parses twice. `readResult` is total for SJON syntax — malformed source
// yields partial roots plus diagnostics, never a throw — while a non-string
// argument is a programmer TypeError, not a syntax diagnostic.
//
// Both entries encode the JS string exactly once and hand the byte view to
// the explicit-frame parser. `fields` lives in `fields.ts` and is re-exported
// here so the public module layout Task 1 declared stays stable.

import type { ReadDiagnostic } from './diagnostics.ts';
import type { Node } from './nodes.ts';
import { parse } from './parser.ts';
import { encodeSource } from './source.ts';

export type { FormFields } from './fields.ts';
export { fields } from './fields.ts';

export interface ReadResult {
  readonly roots: readonly Node[];
  readonly diagnostics: readonly ReadDiagnostic[];
}

/**
 * Thrown by {@link read} when at least one `err`-severity parse diagnostic
 * fired. `result` is the identical single-parse result, so a caller can inspect
 * the recovered roots and every diagnostic that caused the refusal.
 */
export class ReadError extends Error {
  readonly result: ReadResult;

  constructor(result: ReadResult) {
    const head = result.diagnostics.find((diagnostic) => diagnostic.severity === 'err');
    const summary = head ? `${head.code}: ${head.message}` : 'parse failed';
    super(`SJON read failed — ${summary}`);
    this.name = 'ReadError';
    this.result = result;
  }
}

/**
 * Reject a non-string argument as a programmer error before encoding.
 *
 * `TextEncoder` coerces its argument, so without this guard `42`, `null`,
 * `undefined`, or a boxed `String` would be parsed as the literals `"42"`,
 * `"null"`, and so on. That is a mistaken caller, not SJON source, so it is a
 * `TypeError` and never a syntax diagnostic.
 */
function requireSource(source: string): string {
  if (typeof source !== 'string') {
    throw new TypeError(`SJON read expects a string source; received ${typeof source}`);
  }
  return source;
}

/**
 * Total parse: recovered roots and every diagnostic, in engine order.
 *
 * Encodes the source to UTF-8 once, then runs the explicit-frame parser.
 * Never throws for SJON syntax. Complexity O(n) in source bytes; the frame
 * stack is bounded by `MAX_PARSE_DEPTH`.
 */
export function readResult(source: string): ReadResult {
  return parse(encodeSource(requireSource(source)));
}

/**
 * Return roots only when no `err`-severity parse diagnostic fired.
 *
 * Exactly one {@link readResult} call: clean-enough input returns new root
 * arrays the caller owns; otherwise this throws {@link ReadError} carrying that
 * same result. Never parses twice.
 */
export function read(source: string): Node[] {
  const result = readResult(source);
  if (result.diagnostics.some((diagnostic) => diagnostic.severity === 'err')) {
    throw new ReadError(result);
  }
  return [...result.roots];
}
