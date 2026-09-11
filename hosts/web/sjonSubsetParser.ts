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
// The contract, and the reason `refuseUnsupported` exists:
//
//   A successful parse preserves the structure and the values the
//   consumer relies on. Recognised syntax this parser cannot interpret
//   is an explicit error, never a quietly different tree.
//
// Reading a smaller language than SJON is fine and deliberate. Reading
// the *same* text as something else is not, because both consumers act
// on what comes back: the resolver decides which plugin files to load,
// and the conformance reader decides what a case expected. Two
// constructs used to do exactly that.
//
//   `"""raw"""`  lexed as `""` + `"raw"` + `""`, so one string became
//                three nodes: `(plugin :name """shapes""")` gave `:name`
//                the empty string and two stray positionals beside it.
//                A manifest key silently changed value.
//   `#| … |#`    was not trivia here, so its *contents* were parsed as
//                data. A commented-out `:plugins ["disabled.sjon"]`
//                came back as a real kvpair beside the live one, and
//                the resolver indexes every `:plugins` it finds — so
//                text the author disabled became configuration.
//
// Both are lexical features that would fit this node model; supporting
// them is a separate decision. Refusing them is the minimum guarantee.
// LANGUAGE.md §14.2 takes the same line on the wire format: a read that
// cannot be trusted is a loud failure, never a silent one.
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

/**
 * Refuse a construct this parser recognises and cannot interpret. Called
 * only from positions the substrate lexer would treat as a token start,
 * which is what keeps the check off `#` and `"` bytes that are ordinary
 * content: inside a string `parseString` consumes bytes directly, inside
 * a line comment `skipTrivia` runs to the newline, and mid-symbol both
 * `#` and `|` are symbol continuation bytes in `Lexer.zig`'s
 * `symbol_body` — so `a#b` and `foo#|bar` are single symbols here
 * exactly as they are there.
 */
function refuseUnsupported(what: string, spelling: string): never {
  throw new Error(
    `${what} (${spelling}) are unsupported by the bootstrap parser; ` +
      'it reads a subset of SJON and refuses what it would otherwise misread',
  );
}

export function skipTrivia(c: Cursor): void {
  while (c.i < c.src.length) {
    const ch = c.src[c.i];
    if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') c.i++;
    else if (ch === ';') {
      while (c.i < c.src.length && c.src[c.i] !== '\n') c.i++;
    } else if (ch === '#' && c.src[c.i + 1] === '|') {
      // `Lexer.zig`'s `block_hash` state: a `#` at a token start is a
      // block comment when `|` follows and `.invalid` when it does not.
      // Only the first is refused — the second is already malformed
      // SJON, and reading it as a symbol misleads nobody.
      refuseUnsupported('block comments', '`#| … |#`');
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
  // `Lexer.zig` enters `raw_string_body` on exactly three quotes at a
  // token start; `""` and `"foo"` fall through to the escape-aware body.
  // So this tests the same three bytes it does, and an empty `""` still
  // parses — including `""""""`, which is one empty *raw* string there
  // and is refused here rather than read as three empty ones.
  if (c.src[c.i + 1] === '"' && c.src[c.i + 2] === '"') {
    refuseUnsupported('raw strings', '`"""…"""`');
  }
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
