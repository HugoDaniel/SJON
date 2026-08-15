// Tiny SJON-subset parser shared by the two web-host consumers that must
// read SJON text before — or without — sjon.wasm:
//   - createNodeFsResolver.ts — bootstrap-indexes `sjon-project.sjon` and
//     `(plugin …)` manifests to find plugin names/paths before the WASM
//     validator loads.
//   - test/conformance.test.ts — reads `expected.sjon` / `query.sjon`
//     fixtures.
//
// Handles forms, kvpairs (greedy `:k v`), vectors, strings, symbols,
// keywords, line comments (`;`), and whitespace — enough to walk the
// shapes each consumer inspects. The full validating parser lives in
// sjon.wasm; this is only the pre-WASM / test-side substrate.
//
// The two consumers differ in exactly two leaf-lexing choices, captured
// by `Dialect` so each keeps its precise behaviour:
//   - `bareColon` — how a `:` that is NOT a `:k v` separator tokenises.
//     The resolver keeps it a `:`-prefixed symbol (a node it never
//     reads); the conformance reader wants a distinct `keyword` node.
//   - `timeLiterals` — whether `HH:MM:SS[.mmm]` lexes as one symbol. The
//     conformance reader needs it (fixtures carry time literals); a
//     manifest never carries a bare time.

export type FormNode = { tag: 'form'; head: string; children: ParsedNode[] };

export type ParsedNode =
  | FormNode
  | { tag: 'kvpair'; key: string; value: ParsedNode }
  | { tag: 'vector'; elements: ParsedNode[] }
  | { tag: 'string'; value: string }
  | { tag: 'symbol'; value: string }
  | { tag: 'keyword'; value: string };

export interface Cursor {
  src: string;
  i: number;
}

export interface Dialect {
  /** Tokenise a bare `:` (not a `:k v` separator) at the cursor. */
  bareColon: (c: Cursor) => ParsedNode;
  /** Recognise `HH:MM:SS[.mmm]` as a single symbol in `parseAtom`. */
  timeLiterals: boolean;
}

export function skipTrivia(c: Cursor): void {
  while (c.i < c.src.length) {
    const ch = c.src[c.i];
    if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') c.i++;
    else if (ch === ';') {
      while (c.i < c.src.length && c.src[c.i] !== '\n') c.i++;
    } else break;
  }
}

function readSymbol(c: Cursor): string {
  const start = c.i;
  while (c.i < c.src.length) {
    const ch = c.src[c.i];
    if (
      ch === '(' ||
      ch === ')' ||
      ch === '[' ||
      ch === ']' ||
      ch === '"' ||
      ch === ':' ||
      ch === ' ' ||
      ch === '\t' ||
      ch === '\n' ||
      ch === '\r' ||
      ch === ';'
    )
      break;
    c.i++;
  }
  return c.src.slice(start, c.i);
}

function parseString(c: Cursor): ParsedNode {
  c.i++; // consume '"'
  let out = '';
  while (c.i < c.src.length) {
    const ch = c.src[c.i];
    if (ch === '"') {
      c.i++;
      return { tag: 'string', value: out };
    }
    if (ch === '\\') {
      c.i++;
      const esc = c.src[c.i];
      if (esc === 'n') out += '\n';
      else if (esc === 'r') out += '\r';
      else if (esc === 't') out += '\t';
      else out += esc;
      c.i++;
    } else {
      out += ch;
      c.i++;
    }
  }
  throw new Error('unterminated string');
}

function parseAtom(c: Cursor, d: Dialect): ParsedNode {
  let value = readSymbol(c);
  if (value.length === 0) throw new Error(`unexpected character \`${c.src[c.i]}\``);
  // Time-literal continuation: `readSymbol` stops on `:`, so without this
  // `12:34:56` decomposes into [symbol "12", keyword "34", keyword "56"].
  // The substrate parser lexes it as a single `Tag.time`, so a consumer
  // that opts in must too. Match the 6- or 10-char tail after `HH`.
  if (d.timeLiterals && /^\d{2}$/.test(value) && c.src[c.i] === ':') {
    const m = /^:\d{2}:\d{2}(\.\d{3})?/.exec(c.src.slice(c.i));
    if (m !== null) {
      value += m[0];
      c.i += m[0].length;
    }
  }
  return { tag: 'symbol', value };
}

function parseVector(c: Cursor, d: Dialect): ParsedNode {
  c.i++; // consume '['
  const elements: ParsedNode[] = [];
  while (true) {
    skipTrivia(c);
    if (c.i >= c.src.length) throw new Error('unterminated vector');
    if (c.src[c.i] === ']') {
      c.i++;
      return { tag: 'vector', elements };
    }
    elements.push(parseNode(c, d));
  }
}

function parseForm(c: Cursor, d: Dialect): FormNode {
  c.i++; // consume '('
  skipTrivia(c);
  const head = readSymbol(c);
  const children: ParsedNode[] = [];
  while (true) {
    skipTrivia(c);
    if (c.i >= c.src.length) throw new Error('unterminated form');
    if (c.src[c.i] === ')') {
      c.i++;
      return { tag: 'form', head, children };
    }
    if (c.src[c.i] === ':') {
      c.i++;
      const key = readSymbol(c);
      skipTrivia(c);
      const value = parseNode(c, d);
      children.push({ tag: 'kvpair', key, value });
      continue;
    }
    children.push(parseNode(c, d));
  }
}

export function parseNode(c: Cursor, d: Dialect): ParsedNode {
  skipTrivia(c);
  if (c.i >= c.src.length) throw new Error('unexpected end of input');
  const ch = c.src[c.i];
  if (ch === '(') return parseForm(c, d);
  if (ch === '[') return parseVector(c, d);
  if (ch === '"') return parseString(c);
  if (ch === ':') return d.bareColon(c);
  return parseAtom(c, d);
}

/**
 * Resolver dialect. A bare `:name` becomes the `:`-prefixed symbol the
 * resolver's cruder lexer always produced — it never reads such a node
 * (it only inspects `:name`'s symbol/string value), so the shape is
 * irrelevant, but keeping it identical means the extraction is a no-op.
 * No time literals: a manifest never carries a bare `HH:MM:SS`.
 */
export const RESOLVER_DIALECT: Dialect = {
  bareColon: (c) => {
    c.i++; // consume ':'
    return { tag: 'symbol', value: `:${readSymbol(c)}` };
  },
  timeLiterals: false,
};

/** Conformance dialect: a bare `:name` is a keyword node; time literals lex as one symbol. */
export const CONFORMANCE_DIALECT: Dialect = {
  bareColon: (c) => {
    c.i++; // consume ':'
    const value = readSymbol(c);
    if (value.length === 0) throw new Error('expected keyword name after `:`');
    return { tag: 'keyword', value };
  },
  timeLiterals: true,
};
