// AST types for the second-host TypeScript implementation.
//
// Mirrors `src/Ast.zig` at the conceptual level; not a byte-for-byte
// port. Each node is a discriminated union; the parser produces a
// tree of these and the validator walks them. Nodes are loosely
// allocated (no SoA / no arena) — this host prioritises clarity over
// performance.

export type Span = { readonly start: number; readonly end: number };

export type Node =
  | FormNode
  | KvPairNode
  | VectorNode
  | NumberNode
  | DateNode
  | TimeNode
  | StringNode
  | SymbolNode
  | KeywordNode
  | BoolNode
  | NilNode;

export interface FormNode {
  readonly tag: 'form';
  readonly head: string;
  readonly namespace: string | null;
  readonly headSpan: Span;
  readonly children: readonly Node[];
  readonly span: Span;
}

export interface KvPairNode {
  readonly tag: 'kvpair';
  readonly key: string;
  readonly keySpan: Span;
  readonly value: Node;
  readonly span: Span;
}

export interface VectorNode {
  readonly tag: 'vector';
  readonly elements: readonly Node[];
  readonly span: Span;
}

export interface NumberNode {
  readonly tag: 'number';
  readonly value: number;
  readonly unit?: string;
  /** Populated by the parser for pure-integer lexemes (`/^-?\d+$/`).
   *  The bigint preserves the exact magnitude so the validator's
   *  `:numeric` bound check can pick an integer-space comparison
   *  against integer-tag bounds, avoiding f64 round-trip loss above
   *  2^53. Absent for fractional / scientific / unit-bearing
   *  literals. */
  readonly integerBits?: bigint;
  readonly span: Span;
}

/** Calendar-date literal (proleptic Gregorian, no time, no zone).
 *  `year` in [1, 9999], `month` in [1, 12], `day` in [1, daysInMonth].
 *  Mirrors `Ast.Tag.date` in the Zig substrate; the validated invariant
 *  is upheld by `parseNumber`'s date branch. */
export interface DateNode {
  readonly tag: 'date';
  readonly year: number;
  readonly month: number;
  readonly day: number;
  readonly span: Span;
}

/** Clock-time literal (no date, no zone, no leap seconds). `hour` in
 *  [0, 23], `minute` / `second` in [0, 59], `millisecond` in [0, 999].
 *  Mirrors `Ast.Tag.time` in the Zig substrate; the validated invariant
 *  is upheld by `parseNumber`'s time branch. Lex shape is either
 *  `HH:MM:SS` (8 chars) or `HH:MM:SS.fff` (12 chars, exactly 3
 *  fractional digits). */
export interface TimeNode {
  readonly tag: 'time';
  readonly hour: number;
  readonly minute: number;
  readonly second: number;
  readonly millisecond: number;
  readonly span: Span;
}

export interface StringNode {
  readonly tag: 'string';
  readonly value: string;
  readonly span: Span;
}

export interface SymbolNode {
  readonly tag: 'symbol';
  readonly text: string;
  readonly span: Span;
}

export interface KeywordNode {
  readonly tag: 'keyword';
  readonly name: string;
  readonly span: Span;
}

export interface BoolNode {
  readonly tag: 'boolean';
  readonly value: boolean;
  readonly span: Span;
}

export interface NilNode {
  readonly tag: 'nil';
  readonly span: Span;
}
