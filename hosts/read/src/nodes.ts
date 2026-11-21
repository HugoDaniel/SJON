// Public node vocabulary for @sjon-lang/read.
//
// One closed discriminated union on `tag`; `NodeBase.span` is on every variant.
// A span is a half-open **UTF-8 byte** range `[start, end)` into the encoded
// source — never a JS UTF-16 index — including `headSpan` and `keySpan`.
//
// Kvpairs are real tree nodes, so `children` / `elements` keep source order and
// duplicate keys. `fields()` is a view over those nodes, not a second pairing
// pass. The parser that fills these shapes arrives in Tasks 2–5; this module
// only fixes the names and payloads so the parser and its consumers agree.

/** Half-open UTF-8 byte range `[start, end)`. */
export interface Span {
  readonly start: number;
  readonly end: number;
}

/** The one payload every node carries: its span, including delimiters. */
export interface NodeBase {
  readonly span: Span;
}

export interface FormNode extends NodeBase {
  readonly tag: 'form';
  /** Unqualified head: the part after the first interior `/`. */
  readonly head: string;
  /** Prefix before the first interior `/`, or `null` when unqualified. */
  readonly namespace: string | null;
  /** Span of the head token only. */
  readonly headSpan: Span;
  readonly children: readonly Node[];
}

export interface KvpairNode extends NodeBase {
  readonly tag: 'kvpair';
  /** Key body without the leading `:`. */
  readonly key: string;
  /** Span of the key, including its leading `:`. */
  readonly keySpan: Span;
  readonly value: Node;
}

export interface VectorNode extends NodeBase {
  readonly tag: 'vector';
  readonly elements: readonly Node[];
}

export interface NumberNode extends NodeBase {
  readonly tag: 'number';
  /** f64 view of the literal. */
  readonly value: number;
  /** Unit suffix such as `ms` or `deg`, or `null` when unitless. */
  readonly unit: string | null;
  /**
   * Exact value for integer-shaped, unitless literals that fit i64/u64
   * (including hex and underscores); `null` for `1e3`, `1.0`, every
   * unit-bearing literal, and overflow.
   */
  readonly integer: bigint | null;
}

export interface DateNode extends NodeBase {
  readonly tag: 'date';
  readonly year: number;
  readonly month: number;
  readonly day: number;
}

export interface TimeNode extends NodeBase {
  readonly tag: 'time';
  readonly hour: number;
  readonly minute: number;
  readonly second: number;
  readonly millisecond: number;
}

export interface StringNode extends NodeBase {
  readonly tag: 'string';
  /** Decoded value after raw/escape handling. */
  readonly value: string;
}

export interface SymbolNode extends NodeBase {
  readonly tag: 'symbol';
  readonly value: string;
}

export interface KeywordNode extends NodeBase {
  readonly tag: 'keyword';
  /** Keyword body without the leading `:`. */
  readonly value: string;
}

export interface BooleanNode extends NodeBase {
  readonly tag: 'boolean';
  readonly value: boolean;
}

export interface NilNode extends NodeBase {
  readonly tag: 'nil';
}

export type Node =
  | FormNode
  | KvpairNode
  | VectorNode
  | NumberNode
  | DateNode
  | TimeNode
  | StringNode
  | SymbolNode
  | KeywordNode
  | BooleanNode
  | NilNode;
