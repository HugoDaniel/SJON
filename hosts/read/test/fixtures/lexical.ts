// Curated lexical fixtures for Tasks 2–3 of the reader plan.
//
// Every `start` / `end` below is a half-open **UTF-8 byte** offset, not a JS
// string index. The token streams were taken from `src/Lexer.zig` itself
// (the state machine, not the prose) and the string values from
// `Parser.decodeString` — including its permissive `\u{…}` recovery, which is
// correction 4 in docs/plans/consumer-api/README.md: the lexer accepts any
// byte after `\`, and the parser recognises only `n t r " \\ 0`.
//
// `triviaCases` covers BOM, comments, NUL, comma, and `#` placement.
// `stringCases` covers the token stream for every raw and escaped spelling;
// `stringValueCases` covers only what decoding produces (and the diagnostics
// decoding emits). Task 3 extends this file with the number/date/time atoms:
// `numberCases` / `dateCases` / `timeCases` / `atomCases` are checked against
// both `src/Lexer.zig` token spans and the `sjon_node_table` kinds produced by
// the built `sjon.wasm`; `atomRejectCases` pins spellings that stay invalid.

import type { TokenTag } from '../../src/lexer.ts';
import type { Node, Span } from '../../src/nodes.ts';

export interface ExpectedToken {
  readonly tag: TokenTag;
  /**
   * Expected lexeme when its bytes are valid UTF-8. Omitted for a stray
   * byte that is a fragment of a multi-byte sequence (a second BOM), where
   * decoding the one-byte token would manufacture U+FFFD instead of text.
   */
  readonly text?: string;
  readonly start: number;
  readonly end: number;
}

export interface LexicalCase {
  readonly name: string;
  readonly source: string;
  /** Every token before `eof`; the test appends and checks `eof` itself. */
  readonly tokens: readonly ExpectedToken[];
}

export interface ExpectedDiagnostic {
  readonly code: string;
  readonly severity: 'err' | 'warning';
  readonly message: string;
  readonly span: Span;
  readonly path: readonly string[];
}

export interface StringValueCase {
  readonly name: string;
  readonly source: string;
  /** Index into the source's token stream; defaults to the first token. */
  readonly tokenIndex?: number;
  readonly value: string;
  readonly diagnostics: readonly ExpectedDiagnostic[];
}

const BOM = '\uFEFF';
const NUL = '\u0000';

export const triviaCases: readonly LexicalCase[] = [
  {
    name: 'a leading BOM is skipped at offset 0',
    source: `${BOM}(a)`,
    tokens: [
      { tag: 'lparen', text: '(', start: 3, end: 4 },
      { tag: 'symbol', text: 'a', start: 4, end: 5 },
      { tag: 'rparen', text: ')', start: 5, end: 6 },
    ],
  },
  {
    name: 'a second BOM is not skipped: three invalid bytes',
    source: `${BOM}${BOM}a`,
    tokens: [
      { tag: 'invalid', start: 3, end: 4 },
      { tag: 'invalid', start: 4, end: 5 },
      { tag: 'invalid', start: 5, end: 6 },
      { tag: 'symbol', text: 'a', start: 6, end: 7 },
    ],
  },
  {
    name: 'a BOM after offset 0 is three invalid bytes',
    source: `(a) ${BOM}`,
    tokens: [
      { tag: 'lparen', text: '(', start: 0, end: 1 },
      { tag: 'symbol', text: 'a', start: 1, end: 2 },
      { tag: 'rparen', text: ')', start: 2, end: 3 },
      { tag: 'invalid', start: 4, end: 5 },
      { tag: 'invalid', start: 5, end: 6 },
      { tag: 'invalid', start: 6, end: 7 },
    ],
  },
  {
    name: 'a line comment ends before its newline',
    source: '; hi\n(',
    tokens: [
      { tag: 'comment_line', text: '; hi', start: 0, end: 4 },
      { tag: 'lparen', text: '(', start: 5, end: 6 },
    ],
  },
  {
    name: 'a line comment runs to EOF',
    source: '; just a comment',
    tokens: [{ tag: 'comment_line', text: '; just a comment', start: 0, end: 16 }],
  },
  {
    name: 'a line comment accepts a NUL byte as content',
    source: `; a${NUL}b\nx`,
    tokens: [
      { tag: 'comment_line', text: `; a${NUL}b`, start: 0, end: 5 },
      { tag: 'symbol', text: 'x', start: 6, end: 7 },
    ],
  },
  {
    name: 'a block comment closes at |#',
    source: '#| block |# (',
    tokens: [
      { tag: 'comment_block', text: '#| block |#', start: 0, end: 11 },
      { tag: 'lparen', text: '(', start: 12, end: 13 },
    ],
  },
  {
    name: 'block comments do not nest: the first |# closes',
    source: '#| #| inner |# x',
    tokens: [
      { tag: 'comment_block', text: '#| #| inner |#', start: 0, end: 14 },
      { tag: 'symbol', text: 'x', start: 15, end: 16 },
    ],
  },
  {
    name: 'a | not followed by # continues the comment body',
    source: '#| a | b |#',
    tokens: [{ tag: 'comment_block', text: '#| a | b |#', start: 0, end: 11 }],
  },
  {
    name: 'an empty block comment',
    source: '#||#',
    tokens: [{ tag: 'comment_block', text: '#||#', start: 0, end: 4 }],
  },
  {
    name: 'an unterminated block comment is one invalid token',
    source: '#| no end',
    tokens: [{ tag: 'invalid', text: '#| no end', start: 0, end: 9 }],
  },
  {
    name: 'an unterminated block comment treats NUL as content',
    source: `#| a${NUL}b`,
    tokens: [{ tag: 'invalid', text: `#| a${NUL}b`, start: 0, end: 6 }],
  },
  {
    name: 'a stray # stops before the next byte',
    source: '#x',
    tokens: [
      { tag: 'invalid', text: '#', start: 0, end: 1 },
      { tag: 'symbol', text: 'x', start: 1, end: 2 },
    ],
  },
  {
    name: 'a stray # at EOF is invalid',
    source: '#',
    tokens: [{ tag: 'invalid', text: '#', start: 0, end: 1 }],
  },
  {
    name: '# is a symbol-body continuation, not a starter',
    source: 'C#4 D#4',
    tokens: [
      { tag: 'symbol', text: 'C#4', start: 0, end: 3 },
      { tag: 'symbol', text: 'D#4', start: 4, end: 7 },
    ],
  },
  {
    name: 'a double sharp stays one symbol token',
    source: 'C##4',
    tokens: [{ tag: 'symbol', text: 'C##4', start: 0, end: 4 }],
  },
  {
    name: '#| inside a symbol body does not open a comment',
    source: 'foo#|bar',
    tokens: [{ tag: 'symbol', text: 'foo#|bar', start: 0, end: 8 }],
  },
  {
    name: 'a keyword body stops at #',
    source: ':a#b',
    tokens: [
      { tag: 'keyword', text: ':a', start: 0, end: 2 },
      { tag: 'invalid', text: '#', start: 2, end: 3 },
      { tag: 'symbol', text: 'b', start: 3, end: 4 },
    ],
  },
  {
    name: 'a comma is not whitespace: it is one invalid byte',
    source: 'a,b',
    tokens: [
      { tag: 'symbol', text: 'a', start: 0, end: 1 },
      { tag: 'invalid', text: ',', start: 1, end: 2 },
      { tag: 'symbol', text: 'b', start: 2, end: 3 },
    ],
  },
  {
    name: 'NUL outside a string is one invalid byte',
    source: `a${NUL}b`,
    tokens: [
      { tag: 'symbol', text: 'a', start: 0, end: 1 },
      { tag: 'invalid', text: NUL, start: 1, end: 2 },
      { tag: 'symbol', text: 'b', start: 2, end: 3 },
    ],
  },
  {
    name: 'NUL at the start is invalid, not EOF',
    source: `${NUL}a`,
    tokens: [
      { tag: 'invalid', text: NUL, start: 0, end: 1 },
      { tag: 'symbol', text: 'a', start: 1, end: 2 },
    ],
  },
  {
    name: 'NUL at the end is content, not the sentinel',
    source: `a${NUL}`,
    tokens: [
      { tag: 'symbol', text: 'a', start: 0, end: 1 },
      { tag: 'invalid', text: NUL, start: 1, end: 2 },
    ],
  },
  {
    name: ':true is a keyword, not the boolean literal',
    source: ':true',
    tokens: [{ tag: 'keyword', text: ':true', start: 0, end: 5 }],
  },
  {
    name: '::foo is an invalid colon then the keyword :foo',
    source: '::foo',
    tokens: [
      { tag: 'invalid', text: ':', start: 0, end: 1 },
      { tag: 'keyword', text: ':foo', start: 1, end: 5 },
    ],
  },
  {
    name: 'a bare colon is invalid',
    source: ':',
    tokens: [{ tag: 'invalid', text: ':', start: 0, end: 1 }],
  },
  {
    name: '$ and @ start symbol bodies',
    source: '$foo @bar',
    tokens: [
      { tag: 'symbol', text: '$foo', start: 0, end: 4 },
      { tag: 'symbol', text: '@bar', start: 5, end: 9 },
    ],
  },
];

export const stringCases: readonly LexicalCase[] = [
  {
    name: 'an empty string',
    source: '""',
    tokens: [{ tag: 'string', text: '""', start: 0, end: 2 }],
  },
  {
    name: 'an empty raw string',
    source: '""""""',
    tokens: [{ tag: 'raw_string', text: '""""""', start: 0, end: 6 }],
  },
  {
    name: 'a single-line raw string',
    source: '"""hello"""',
    tokens: [{ tag: 'raw_string', text: '"""hello"""', start: 0, end: 11 }],
  },
  {
    name: 'a multiline raw string keeps its newlines',
    source: '"""\nhello\n"""',
    tokens: [{ tag: 'raw_string', text: '"""\nhello\n"""', start: 0, end: 13 }],
  },
  {
    name: 'raw backslashes are literal bytes',
    source: '"""\\n\\tX"""',
    tokens: [{ tag: 'raw_string', text: '"""\\n\\tX"""', start: 0, end: 11 }],
  },
  {
    name: 'one and two embedded quotes stay raw content',
    source: '"""a"x""y"""',
    tokens: [{ tag: 'raw_string', text: '"""a"x""y"""', start: 0, end: 12 }],
  },
  {
    name: 'a raw string closes greedily at the first three quotes',
    source: '""""abc"""',
    tokens: [{ tag: 'raw_string', text: '""""abc"""', start: 0, end: 10 }],
  },
  {
    name: 'a two-quote body prefix is content',
    source: '"""""prefix"""',
    tokens: [{ tag: 'raw_string', text: '"""""prefix"""', start: 0, end: 14 }],
  },
  {
    name: 'an unterminated raw string is one invalid token',
    source: '"""oops',
    tokens: [{ tag: 'invalid', text: '"""oops', start: 0, end: 7 }],
  },
  {
    name: 'a bare raw opener is invalid',
    source: '"""',
    tokens: [{ tag: 'invalid', text: '"""', start: 0, end: 3 }],
  },
  {
    name: 'a raw opener closed by only two quotes is invalid',
    source: '"""ab""',
    tokens: [{ tag: 'invalid', text: '"""ab""', start: 0, end: 7 }],
  },
  {
    name: 'quotes after a raw close start a fresh invalid opener',
    source: '"""abc""""""',
    tokens: [
      { tag: 'raw_string', text: '"""abc"""', start: 0, end: 9 },
      { tag: 'invalid', text: '"""', start: 9, end: 12 },
    ],
  },
  {
    name: 'two adjacent raw strings reset cleanly',
    source: '"""a""""""b"""',
    tokens: [
      { tag: 'raw_string', text: '"""a"""', start: 0, end: 7 },
      { tag: 'raw_string', text: '"""b"""', start: 7, end: 14 },
    ],
  },
  {
    name: 'a raw body hides comment and structural sigils',
    source: '"""; no\n#| nope |#\n( [ : """',
    tokens: [{ tag: 'raw_string', text: '"""; no\n#| nope |#\n( [ : """', start: 0, end: 28 }],
  },
  {
    name: 'NUL inside a raw body is content',
    source: `"""a${NUL}b"""`,
    tokens: [{ tag: 'raw_string', text: `"""a${NUL}b"""`, start: 0, end: 9 }],
  },
  {
    name: 'UTF-8 inside a raw body is content',
    source: '"""héllo 你好 🦀"""',
    tokens: [{ tag: 'raw_string', text: '"""héllo 你好 🦀"""', start: 0, end: 24 }],
  },
  {
    name: 'a raw string is adjacent to other tokens without whitespace',
    source: '(s"""x""")',
    tokens: [
      { tag: 'lparen', text: '(', start: 0, end: 1 },
      { tag: 'symbol', text: 's', start: 1, end: 2 },
      { tag: 'raw_string', text: '"""x"""', start: 2, end: 9 },
      { tag: 'rparen', text: ')', start: 9, end: 10 },
    ],
  },
  {
    name: 'an unterminated string is one invalid token',
    source: '"oops',
    tokens: [{ tag: 'invalid', text: '"oops', start: 0, end: 5 }],
  },
  {
    name: 'a lone quote is invalid',
    source: '"',
    tokens: [{ tag: 'invalid', text: '"', start: 0, end: 1 }],
  },
  {
    name: 'a backslash at EOF is invalid',
    source: '"\\',
    tokens: [{ tag: 'invalid', text: '"\\', start: 0, end: 2 }],
  },
  {
    name: 'NUL inside a string body is content',
    source: `"a${NUL}b"`,
    tokens: [{ tag: 'string', text: `"a${NUL}b"`, start: 0, end: 5 }],
  },
  {
    name: 'NUL after a backslash is not an escape target',
    source: `"a\\${NUL}b"`,
    tokens: [
      { tag: 'invalid', text: '"a\\', start: 0, end: 3 },
      { tag: 'invalid', text: NUL, start: 3, end: 4 },
      { tag: 'symbol', text: 'b', start: 4, end: 5 },
      { tag: 'invalid', text: '"', start: 5, end: 6 },
    ],
  },
  {
    name: 'an unescaped newline inside a string is content',
    source: '"a\nb"',
    tokens: [{ tag: 'string', text: '"a\nb"', start: 0, end: 5 }],
  },
  {
    name: 'escaped quotes stay inside one string token',
    source: '"with \\"quote\\""',
    tokens: [{ tag: 'string', text: '"with \\"quote\\""', start: 0, end: 16 }],
  },
  {
    name: 'the token after a non-ASCII string keeps a byte span',
    source: '"héllo ☀️" node',
    tokens: [
      { tag: 'string', text: '"héllo ☀️"', start: 0, end: 15 },
      { tag: 'symbol', text: 'node', start: 16, end: 20 },
    ],
  },
  {
    name: 'every implemented escape is one string token',
    source: '"a\\nb\\tc\\rd\\\\e\\"f\\0g"',
    tokens: [{ tag: 'string', text: '"a\\nb\\tc\\rd\\\\e\\"f\\0g"', start: 0, end: 21 }],
  },
  {
    name: 'an unknown escape stays one string token',
    source: '"hello\\qworld"',
    tokens: [{ tag: 'string', text: '"hello\\qworld"', start: 0, end: 14 }],
  },
  {
    name: '\\u{1F600} stays one string token (the lexer reads one escape byte)',
    source: '"\\u{1F600}"',
    tokens: [{ tag: 'string', text: '"\\u{1F600}"', start: 0, end: 11 }],
  },
  {
    name: 'a malformed \\u{} shape stays one string token',
    source: '"\\u{}"',
    tokens: [{ tag: 'string', text: '"\\u{}"', start: 0, end: 6 }],
  },
];

export const stringValueCases: readonly StringValueCase[] = [
  {
    name: 'an empty escaped string decodes to the empty string',
    source: '""',
    value: '',
    diagnostics: [],
  },
  {
    name: 'an empty raw string decodes to the empty string',
    source: '""""""',
    value: '',
    diagnostics: [],
  },
  {
    name: 'a raw body decodes verbatim (no dedent, no trim)',
    source: '"""\n  hello\n"""',
    value: '\n  hello\n',
    diagnostics: [],
  },
  {
    name: 'raw backslash sequences are not escapes',
    source: '"""\\n\\tX"""',
    value: '\\n\\tX',
    diagnostics: [],
  },
  {
    name: 'raw embedded quotes decode verbatim',
    source: '"""a"x""y"""',
    value: 'a"x""y',
    diagnostics: [],
  },
  {
    name: 'a greedy raw close leaves one quote in the body',
    source: '""""abc"""',
    value: '"abc',
    diagnostics: [],
  },
  {
    name: 'a two-quote body prefix decodes verbatim',
    source: '"""""prefix"""',
    value: '""prefix',
    diagnostics: [],
  },
  {
    name: 'NUL inside a raw body decodes to a NUL value byte',
    source: `"""a${NUL}b"""`,
    value: `a${NUL}b`,
    diagnostics: [],
  },
  {
    name: 'UTF-8 inside a raw body decodes verbatim',
    source: '"""héllo 你好 🦀"""',
    value: 'héllo 你好 🦀',
    diagnostics: [],
  },
  {
    name: 'every implemented escape decodes to its runtime byte',
    source: '"a\\nb\\tc\\rd\\\\e\\"f\\0g"',
    value: 'a\nb\tc\rd\\e"f\u0000g',
    diagnostics: [],
  },
  {
    name: '\\n decodes to a newline',
    source: '"\\n"',
    value: '\n',
    diagnostics: [],
  },
  {
    name: '\\t decodes to a tab',
    source: '"\\t"',
    value: '\t',
    diagnostics: [],
  },
  {
    name: '\\r decodes to a carriage return',
    source: '"\\r"',
    value: '\r',
    diagnostics: [],
  },
  {
    name: '\\\\ decodes to one backslash',
    source: '"\\\\"',
    value: '\\',
    diagnostics: [],
  },
  {
    name: '\\" decodes to one quote',
    source: '"\\""',
    value: '"',
    diagnostics: [],
  },
  {
    name: '\\0 decodes to a NUL value byte',
    source: '"\\0"',
    value: '\u0000',
    diagnostics: [],
  },
  {
    name: 'an unknown escape keeps its following byte and diagnoses',
    source: '"hello\\qworld"',
    value: 'helloqworld',
    diagnostics: [
      {
        code: 'unspecified',
        severity: 'err',
        message: 'unrecognized string escape',
        span: { start: 0, end: 14 },
        path: [],
      },
    ],
  },
  {
    name: '\\u{1F600} is an unknown \\u escape plus literal text, not a codepoint',
    source: '"\\u{1F600}"',
    value: 'u{1F600}',
    diagnostics: [
      {
        code: 'unspecified',
        severity: 'err',
        message: 'unrecognized string escape',
        span: { start: 0, end: 11 },
        path: [],
      },
    ],
  },
  {
    name: 'a malformed \\u{} shape decodes to u{} plus a diagnostic',
    source: '"\\u{}"',
    value: 'u{}',
    diagnostics: [
      {
        code: 'unspecified',
        severity: 'err',
        message: 'unrecognized string escape',
        span: { start: 0, end: 6 },
        path: [],
      },
    ],
  },
  {
    name: 'two unknown escapes diagnose twice, in source order',
    source: '"\\q\\z"',
    value: 'qz',
    diagnostics: [
      {
        code: 'unspecified',
        severity: 'err',
        message: 'unrecognized string escape',
        span: { start: 0, end: 6 },
        path: [],
      },
      {
        code: 'unspecified',
        severity: 'err',
        message: 'unrecognized string escape',
        span: { start: 0, end: 6 },
        path: [],
      },
    ],
  },
  {
    name: 'NUL inside an escaped string is content, not an escape',
    source: `"a${NUL}b"`,
    value: `a${NUL}b`,
    diagnostics: [],
  },
  {
    name: 'a literal newline inside an escaped string decodes to a newline',
    source: '"a\nb"',
    value: 'a\nb',
    diagnostics: [],
  },
  {
    name: 'non-ASCII string content decodes losslessly',
    source: '"héllo ☀️"',
    value: 'héllo ☀️',
    diagnostics: [],
  },
  {
    name: 'a lone surrogate encodes as U+FFFD before lexing',
    source: '"\uD800"',
    value: '\uFFFD',
    diagnostics: [],
  },
];

// ---------------------------------------------------------------------------
// Task 3: numbers, dates, times, and the remaining leaf tokens.
//
// Every expectation below is the engine's result, checked against
// `src/Lexer.zig` (spans) and `sjon_node_table` / `sjon_to_json` from the
// built `sjon.wasm` (kind, unit, exact integer, date/time fields, and
// diagnostics). `integer` is the bigint classification that the public
// `NumberNode.integer` carries; it is null for every unit-bearing or
// float-shaped spelling and for true i64/u64 overflow.
// ---------------------------------------------------------------------------

export type AtomExpectation =
  | {
      readonly tag: 'number';
      readonly value: number;
      readonly unit: string | null;
      readonly integer: bigint | null;
    }
  | {
      readonly tag: 'date';
      readonly year: number;
      readonly month: number;
      readonly day: number;
    }
  | {
      readonly tag: 'time';
      readonly hour: number;
      readonly minute: number;
      readonly second: number;
      readonly millisecond: number;
    }
  | { readonly tag: 'string'; readonly value: string }
  | { readonly tag: 'symbol'; readonly value: string }
  | { readonly tag: 'keyword'; readonly value: string }
  | { readonly tag: 'boolean'; readonly value: boolean }
  | { readonly tag: 'nil' };

export interface AtomCase {
  readonly name: string;
  readonly source: string;
  /** Full token stream before `eof`, from `src/Lexer.zig`. */
  readonly tokens: readonly ExpectedToken[];
  /** Which token the expectation describes; defaults to the first token. */
  readonly tokenIndex?: number;
  readonly expected: AtomExpectation;
  readonly diagnostics: readonly ExpectedDiagnostic[];
}

const NUMBER_OVERFLOW_MESSAGE = 'integer literal exceeds u64 range; storing as approximate f64';
const DATE_INVALID_YEAR_MESSAGE = 'date year out of range (1..9999)';
const DATE_INVALID_MONTH_MESSAGE = 'date month out of range (1..12)';
const DATE_INVALID_DAY_MESSAGE = 'date day out of range for the given year and month';
const TIME_INVALID_HOUR_MESSAGE = 'time hour out of range (0..23)';
const TIME_INVALID_MINUTE_MESSAGE = 'time minute out of range (0..59)';
const TIME_INVALID_SECOND_MESSAGE = 'time second out of range (0..59)';

function atomError(code: string, message: string, start: number, end: number): ExpectedDiagnostic {
  return { code, severity: 'err', message, span: { start, end }, path: [] };
}

/**
 * Project one reader leaf onto the expectation shape, dropping `span` (the
 * tests assert the span against the token separately) so a fixture is a
 * pure value comparison. Containers are not atoms.
 */
export function projectAtom(node: Node): AtomExpectation {
  switch (node.tag) {
    case 'number':
      return { tag: 'number', value: node.value, unit: node.unit, integer: node.integer };
    case 'date':
      return { tag: 'date', year: node.year, month: node.month, day: node.day };
    case 'time':
      return {
        tag: 'time',
        hour: node.hour,
        minute: node.minute,
        second: node.second,
        millisecond: node.millisecond,
      };
    case 'string':
      return { tag: 'string', value: node.value };
    case 'symbol':
      return { tag: 'symbol', value: node.value };
    case 'keyword':
      return { tag: 'keyword', value: node.value };
    case 'boolean':
      return { tag: 'boolean', value: node.value };
    case 'nil':
      return { tag: 'nil' };
    case 'form':
    case 'kvpair':
    case 'vector':
      throw new TypeError(`expected an atom, got ${node.tag}`);
  }
}

export const numberCases: readonly AtomCase[] = [
  {
    name: '4b is the number 4 with unit b',
    source: '4b',
    tokens: [{ tag: 'number', text: '4b', start: 0, end: 2 }],
    expected: { tag: 'number', value: 4, unit: 'b', integer: null },
    diagnostics: [],
  },
  {
    name: '90deg is 90 degrees, not a decimal with unit g',
    source: '90deg',
    tokens: [{ tag: 'number', text: '90deg', start: 0, end: 5 }],
    expected: { tag: 'number', value: 90, unit: 'deg', integer: null },
    diagnostics: [],
  },
  {
    name: '50% carries the percent unit',
    source: '50%',
    tokens: [{ tag: 'number', text: '50%', start: 0, end: 3 }],
    expected: { tag: 'number', value: 50, unit: '%', integer: null },
    diagnostics: [],
  },
  {
    name: '250ms is a unit-bearing number',
    source: '250ms',
    tokens: [{ tag: 'number', text: '250ms', start: 0, end: 5 }],
    expected: { tag: 'number', value: 250, unit: 'ms', integer: null },
    diagnostics: [],
  },
  {
    name: '1.5e2hz keeps both its exponent value and its unit',
    source: '1.5e2hz',
    tokens: [{ tag: 'number', text: '1.5e2hz', start: 0, end: 7 }],
    expected: { tag: 'number', value: 150, unit: 'hz', integer: null },
    diagnostics: [],
  },
  {
    name: '2d-array is the number 2 with a hyphenated unit',
    source: '2d-array',
    tokens: [{ tag: 'number', text: '2d-array', start: 0, end: 8 }],
    expected: { tag: 'number', value: 2, unit: 'd-array', integer: null },
    diagnostics: [],
  },
  {
    name: '5ms-per-frame is the number 5 with a hyphenated unit',
    source: '5ms-per-frame',
    tokens: [{ tag: 'number', text: '5ms-per-frame', start: 0, end: 13 }],
    expected: { tag: 'number', value: 5, unit: 'ms-per-frame', integer: null },
    diagnostics: [],
  },
  {
    name: '1em is 1 with unit em, not an exponent with a missing digit',
    source: '1em',
    tokens: [{ tag: 'number', text: '1em', start: 0, end: 3 }],
    expected: { tag: 'number', value: 1, unit: 'em', integer: null },
    diagnostics: [],
  },
  {
    name: '1e9 is a float-shaped literal with no exact integer',
    source: '1e9',
    tokens: [{ tag: 'number', text: '1e9', start: 0, end: 3 }],
    expected: { tag: 'number', value: 1e9, unit: null, integer: null },
    diagnostics: [],
  },
  {
    name: '1.5e-10 is a float-shaped literal with no exact integer',
    source: '1.5e-10',
    tokens: [{ tag: 'number', text: '1.5e-10', start: 0, end: 7 }],
    expected: { tag: 'number', value: 1.5e-10, unit: null, integer: null },
    diagnostics: [],
  },
  {
    name: '90deg5px splits into two numbers: the first is 90deg',
    source: '90deg5px',
    tokens: [
      { tag: 'number', text: '90deg', start: 0, end: 5 },
      { tag: 'number', text: '5px', start: 5, end: 8 },
    ],
    expected: { tag: 'number', value: 90, unit: 'deg', integer: null },
    diagnostics: [],
  },
  {
    name: '90deg5px splits into two numbers: the second is 5px',
    source: '90deg5px',
    tokens: [
      { tag: 'number', text: '90deg', start: 0, end: 5 },
      { tag: 'number', text: '5px', start: 5, end: 8 },
    ],
    tokenIndex: 1,
    expected: { tag: 'number', value: 5, unit: 'px', integer: null },
    diagnostics: [],
  },
  {
    name: '1em-2 stops the unit before a dash that is not followed by a letter',
    source: '1em-2',
    tokens: [
      { tag: 'number', text: '1em', start: 0, end: 3 },
      { tag: 'number', text: '-2', start: 3, end: 5 },
    ],
    expected: { tag: 'number', value: 1, unit: 'em', integer: null },
    diagnostics: [],
  },
  {
    name: '1em-2 leaves -2 as a separate exact integer',
    source: '1em-2',
    tokens: [
      { tag: 'number', text: '1em', start: 0, end: 3 },
      { tag: 'number', text: '-2', start: 3, end: 5 },
    ],
    tokenIndex: 1,
    expected: { tag: 'number', value: -2, unit: null, integer: -2n },
    diagnostics: [],
  },
  {
    name: '1_000ms strips the underscore before the unit',
    source: '1_000ms',
    tokens: [{ tag: 'number', text: '1_000ms', start: 0, end: 7 }],
    expected: { tag: 'number', value: 1000, unit: 'ms', integer: null },
    diagnostics: [],
  },
  {
    name: '12foo is the number 12 with unit foo',
    source: '12foo',
    tokens: [{ tag: 'number', text: '12foo', start: 0, end: 5 }],
    expected: { tag: 'number', value: 12, unit: 'foo', integer: null },
    diagnostics: [],
  },
  {
    name: '1. is a float-shaped 1, not an exact integer',
    source: '1.',
    tokens: [{ tag: 'number', text: '1.', start: 0, end: 2 }],
    expected: { tag: 'number', value: 1, unit: null, integer: null },
    diagnostics: [],
  },
  {
    name: '1.e2hz reads the .e as a unit because no digit follows the dot',
    source: '1.e2hz',
    tokens: [
      { tag: 'number', text: '1.e', start: 0, end: 3 },
      { tag: 'number', text: '2hz', start: 3, end: 6 },
    ],
    expected: { tag: 'number', value: 1, unit: 'e', integer: null },
    diagnostics: [],
  },
  {
    name: '1.e2hz leaves 2hz as the second number',
    source: '1.e2hz',
    tokens: [
      { tag: 'number', text: '1.e', start: 0, end: 3 },
      { tag: 'number', text: '2hz', start: 3, end: 6 },
    ],
    tokenIndex: 1,
    expected: { tag: 'number', value: 2, unit: 'hz', integer: null },
    diagnostics: [],
  },
  {
    name: '1e is the number 1 with unit e, not an exponent marker',
    source: '1e',
    tokens: [{ tag: 'number', text: '1e', start: 0, end: 2 }],
    expected: { tag: 'number', value: 1, unit: 'e', integer: null },
    diagnostics: [],
  },
  {
    name: '1_e3 strips the underscore and then reads the exponent',
    source: '1_e3',
    tokens: [{ tag: 'number', text: '1_e3', start: 0, end: 4 }],
    expected: { tag: 'number', value: 1000, unit: null, integer: null },
    diagnostics: [],
  },
  {
    name: '1e3_0 strips an exponent underscore',
    source: '1e3_0',
    tokens: [{ tag: 'number', text: '1e3_0', start: 0, end: 5 }],
    expected: { tag: 'number', value: 1e30, unit: null, integer: null },
    diagnostics: [],
  },
  {
    name: 'a trailing underscore is still an exact integer',
    source: '1_',
    tokens: [{ tag: 'number', text: '1_', start: 0, end: 2 }],
    expected: { tag: 'number', value: 1, unit: null, integer: 1n },
    diagnostics: [],
  },
  {
    name: 'a doubled underscore is still an exact integer',
    source: '1__0',
    tokens: [{ tag: 'number', text: '1__0', start: 0, end: 4 }],
    expected: { tag: 'number', value: 10, unit: null, integer: 10n },
    diagnostics: [],
  },
  {
    name: '0b101 is 0 with unit b, not a binary literal',
    source: '0b101',
    tokens: [
      { tag: 'number', text: '0b', start: 0, end: 2 },
      { tag: 'number', text: '101', start: 2, end: 5 },
    ],
    expected: { tag: 'number', value: 0, unit: 'b', integer: null },
    diagnostics: [],
  },
  {
    name: '0b101 leaves 101 as a separate exact integer',
    source: '0b101',
    tokens: [
      { tag: 'number', text: '0b', start: 0, end: 2 },
      { tag: 'number', text: '101', start: 2, end: 5 },
    ],
    tokenIndex: 1,
    expected: { tag: 'number', value: 101, unit: null, integer: 101n },
    diagnostics: [],
  },
  {
    name: '0o17 is 0 with unit o, not an octal literal',
    source: '0o17',
    tokens: [
      { tag: 'number', text: '0o', start: 0, end: 2 },
      { tag: 'number', text: '17', start: 2, end: 4 },
    ],
    expected: { tag: 'number', value: 0, unit: 'o', integer: null },
    diagnostics: [],
  },
  {
    name: 'a second dot is not part of the first number',
    source: '1..2',
    tokens: [
      { tag: 'number', text: '1.', start: 0, end: 2 },
      { tag: 'symbol', text: '.2', start: 2, end: 4 },
    ],
    expected: { tag: 'number', value: 1, unit: null, integer: null },
    diagnostics: [],
  },
  {
    name: '1.2.3 stops the number at the second dot',
    source: '1.2.3',
    tokens: [
      { tag: 'number', text: '1.2', start: 0, end: 3 },
      { tag: 'symbol', text: '.3', start: 3, end: 5 },
    ],
    expected: { tag: 'number', value: 1.2, unit: null, integer: null },
    diagnostics: [],
  },
  {
    name: '1e+2 is a float-shaped 100',
    source: '1e+2',
    tokens: [{ tag: 'number', text: '1e+2', start: 0, end: 4 }],
    expected: { tag: 'number', value: 100, unit: null, integer: null },
    diagnostics: [],
  },
  {
    name: '1E5ms is 100000 milliseconds',
    source: '1E5ms',
    tokens: [{ tag: 'number', text: '1E5ms', start: 0, end: 5 }],
    expected: { tag: 'number', value: 100000, unit: 'ms', integer: null },
    diagnostics: [],
  },
  {
    name: '0.5x is a float with unit x',
    source: '0.5x',
    tokens: [{ tag: 'number', text: '0.5x', start: 0, end: 4 }],
    expected: { tag: 'number', value: 0.5, unit: 'x', integer: null },
    diagnostics: [],
  },
  {
    name: '0_x is 0 with unit x, not a hex prefix',
    source: '0_x',
    tokens: [{ tag: 'number', text: '0_x', start: 0, end: 3 }],
    expected: { tag: 'number', value: 0, unit: 'x', integer: null },
    diagnostics: [],
  },
  {
    name: '-0x0 is an exact integer zero (hex has no negative zero)',
    source: '-0x0',
    tokens: [{ tag: 'number', text: '-0x0', start: 0, end: 4 }],
    expected: { tag: 'number', value: 0, unit: null, integer: 0n },
    diagnostics: [],
  },
  {
    name: '0xFF is exact 255',
    source: '0xFF',
    tokens: [{ tag: 'number', text: '0xFF', start: 0, end: 4 }],
    expected: { tag: 'number', value: 255, unit: null, integer: 255n },
    diagnostics: [],
  },
  {
    name: '0Xff accepts an uppercase prefix',
    source: '0Xff',
    tokens: [{ tag: 'number', text: '0Xff', start: 0, end: 4 }],
    expected: { tag: 'number', value: 255, unit: null, integer: 255n },
    diagnostics: [],
  },
  {
    name: '0xdeadBEEF preserves lowercase and uppercase digits',
    source: '0xdeadBEEF',
    tokens: [{ tag: 'number', text: '0xdeadBEEF', start: 0, end: 10 }],
    expected: {
      tag: 'number',
      value: 3735928559,
      unit: null,
      integer: 3735928559n,
    },
    diagnostics: [],
  },
  {
    name: '0xFFFF_FFFF strips hex underscores',
    source: '0xFFFF_FFFF',
    tokens: [{ tag: 'number', text: '0xFFFF_FFFF', start: 0, end: 11 }],
    expected: { tag: 'number', value: 4294967295, unit: null, integer: 4294967295n },
    diagnostics: [],
  },
  {
    name: '-0x10 is exact -16',
    source: '-0x10',
    tokens: [{ tag: 'number', text: '-0x10', start: 0, end: 5 }],
    expected: { tag: 'number', value: -16, unit: null, integer: -16n },
    diagnostics: [],
  },
  {
    name: '0xFFms is the hex number 0xFF then a symbol, not a unit',
    source: '0xFFms',
    tokens: [
      { tag: 'number', text: '0xFF', start: 0, end: 4 },
      { tag: 'symbol', text: 'ms', start: 4, end: 6 },
    ],
    expected: { tag: 'number', value: 255, unit: null, integer: 255n },
    diagnostics: [],
  },
  {
    name: '0x7FFF_FFFF_FFFF_FFFF is exactly i64.max',
    source: '0x7FFF_FFFF_FFFF_FFFF',
    tokens: [{ tag: 'number', text: '0x7FFF_FFFF_FFFF_FFFF', start: 0, end: 21 }],
    expected: {
      tag: 'number',
      value: Number(9_223_372_036_854_775_807n),
      unit: null,
      integer: 9_223_372_036_854_775_807n,
    },
    diagnostics: [],
  },
  {
    name: '0x8000_0000_0000_0000 is exactly 2^63 in u64',
    source: '0x8000_0000_0000_0000',
    tokens: [{ tag: 'number', text: '0x8000_0000_0000_0000', start: 0, end: 21 }],
    expected: {
      tag: 'number',
      value: Number(9_223_372_036_854_775_808n),
      unit: null,
      integer: 9_223_372_036_854_775_808n,
    },
    diagnostics: [],
  },
  {
    name: '0xFFFF_FFFF_FFFF_FFFF is exactly u64.max',
    source: '0xFFFF_FFFF_FFFF_FFFF',
    tokens: [{ tag: 'number', text: '0xFFFF_FFFF_FFFF_FFFF', start: 0, end: 21 }],
    expected: {
      tag: 'number',
      value: Number(18_446_744_073_709_551_615n),
      unit: null,
      integer: 18_446_744_073_709_551_615n,
    },
    diagnostics: [],
  },
  {
    name: '0x1_0000_0000_0000_0000 overflows exact storage',
    source: '0x1_0000_0000_0000_0000',
    tokens: [{ tag: 'number', text: '0x1_0000_0000_0000_0000', start: 0, end: 23 }],
    expected: {
      tag: 'number',
      value: Number(18_446_744_073_709_551_616n),
      unit: null,
      integer: null,
    },
    diagnostics: [atomError('number_overflow_exact_integer', NUMBER_OVERFLOW_MESSAGE, 0, 23)],
  },
  {
    name: '-0x8000_0000_0000_0000 is exactly i64.min',
    source: '-0x8000_0000_0000_0000',
    tokens: [{ tag: 'number', text: '-0x8000_0000_0000_0000', start: 0, end: 22 }],
    expected: {
      tag: 'number',
      value: Number(-9_223_372_036_854_775_808n),
      unit: null,
      integer: -9_223_372_036_854_775_808n,
    },
    diagnostics: [],
  },
  {
    name: '-0x8000_0000_0000_0001 overflows below i64.min',
    source: '-0x8000_0000_0000_0001',
    tokens: [{ tag: 'number', text: '-0x8000_0000_0000_0001', start: 0, end: 22 }],
    expected: {
      tag: 'number',
      value: Number(-9_223_372_036_854_775_809n),
      unit: null,
      integer: null,
    },
    diagnostics: [atomError('number_overflow_exact_integer', NUMBER_OVERFLOW_MESSAGE, 0, 22)],
  },
  {
    name: '0x1_ strips a hex underscore without losing the digit',
    source: '0x1_',
    tokens: [{ tag: 'number', text: '0x1_', start: 0, end: 4 }],
    expected: { tag: 'number', value: 1, unit: null, integer: 1n },
    diagnostics: [],
  },
  {
    name: '9223372036854775807 is exactly i64.max',
    source: '9223372036854775807',
    tokens: [{ tag: 'number', text: '9223372036854775807', start: 0, end: 19 }],
    expected: {
      tag: 'number',
      value: Number(9_223_372_036_854_775_807n),
      unit: null,
      integer: 9_223_372_036_854_775_807n,
    },
    diagnostics: [],
  },
  {
    name: '9223372036854775808 is exactly 2^63 in u64',
    source: '9223372036854775808',
    tokens: [{ tag: 'number', text: '9223372036854775808', start: 0, end: 19 }],
    expected: {
      tag: 'number',
      value: Number(9_223_372_036_854_775_808n),
      unit: null,
      integer: 9_223_372_036_854_775_808n,
    },
    diagnostics: [],
  },
  {
    name: '18446744073709551615 is exactly u64.max',
    source: '18446744073709551615',
    tokens: [{ tag: 'number', text: '18446744073709551615', start: 0, end: 20 }],
    expected: {
      tag: 'number',
      value: Number(18_446_744_073_709_551_615n),
      unit: null,
      integer: 18_446_744_073_709_551_615n,
    },
    diagnostics: [],
  },
  {
    name: '18446744073709551616 overflows exact storage',
    source: '18446744073709551616',
    tokens: [{ tag: 'number', text: '18446744073709551616', start: 0, end: 20 }],
    expected: {
      tag: 'number',
      value: Number(18_446_744_073_709_551_616n),
      unit: null,
      integer: null,
    },
    diagnostics: [atomError('number_overflow_exact_integer', NUMBER_OVERFLOW_MESSAGE, 0, 20)],
  },
  {
    name: '-9223372036854775808 is exactly i64.min',
    source: '-9223372036854775808',
    tokens: [{ tag: 'number', text: '-9223372036854775808', start: 0, end: 20 }],
    expected: {
      tag: 'number',
      value: Number(-9_223_372_036_854_775_808n),
      unit: null,
      integer: -9_223_372_036_854_775_808n,
    },
    diagnostics: [],
  },
  {
    name: '-9223372036854775809 overflows below i64.min',
    source: '-9223372036854775809',
    tokens: [{ tag: 'number', text: '-9223372036854775809', start: 0, end: 20 }],
    expected: {
      tag: 'number',
      value: Number(-9_223_372_036_854_775_809n),
      unit: null,
      integer: null,
    },
    diagnostics: [atomError('number_overflow_exact_integer', NUMBER_OVERFLOW_MESSAGE, 0, 20)],
  },
  {
    name: '1_000_000 is an exact integer after underscore stripping',
    source: '1_000_000',
    tokens: [{ tag: 'number', text: '1_000_000', start: 0, end: 9 }],
    expected: {
      tag: 'number',
      value: 1_000_000,
      unit: null,
      integer: 1_000_000n,
    },
    diagnostics: [],
  },
  {
    name: '1e3 is float-shaped, so integer is null',
    source: '1e3',
    tokens: [{ tag: 'number', text: '1e3', start: 0, end: 3 }],
    expected: { tag: 'number', value: 1000, unit: null, integer: null },
    diagnostics: [],
  },
  {
    name: '1.0 is float-shaped, so integer is null',
    source: '1.0',
    tokens: [{ tag: 'number', text: '1.0', start: 0, end: 3 }],
    expected: { tag: 'number', value: 1, unit: null, integer: null },
    diagnostics: [],
  },
  {
    name: '-0 is exact integer zero with a negative-zero f64 view',
    source: '-0',
    tokens: [{ tag: 'number', text: '-0', start: 0, end: 2 }],
    expected: { tag: 'number', value: -0, unit: null, integer: 0n },
    diagnostics: [],
  },
  {
    name: '-0.0 is a float-shaped negative zero with no exact integer',
    source: '-0.0',
    tokens: [{ tag: 'number', text: '-0.0', start: 0, end: 4 }],
    expected: { tag: 'number', value: -0, unit: null, integer: null },
    diagnostics: [],
  },
];

export const dateCases: readonly AtomCase[] = [
  {
    name: '0001-01-01 is the minimum date',
    source: '0001-01-01',
    tokens: [{ tag: 'date', text: '0001-01-01', start: 0, end: 10 }],
    expected: { tag: 'date', year: 1, month: 1, day: 1 },
    diagnostics: [],
  },
  {
    name: '9999-12-31 is the maximum date',
    source: '9999-12-31',
    tokens: [{ tag: 'date', text: '9999-12-31', start: 0, end: 10 }],
    expected: { tag: 'date', year: 9999, month: 12, day: 31 },
    diagnostics: [],
  },
  {
    name: '2024-02-29 is a Gregorian leap day',
    source: '2024-02-29',
    tokens: [{ tag: 'date', text: '2024-02-29', start: 0, end: 10 }],
    expected: { tag: 'date', year: 2024, month: 2, day: 29 },
    diagnostics: [],
  },
  {
    name: '2000-02-29 is a leap day because 2000 is divisible by 400',
    source: '2000-02-29',
    tokens: [{ tag: 'date', text: '2000-02-29', start: 0, end: 10 }],
    expected: { tag: 'date', year: 2000, month: 2, day: 29 },
    diagnostics: [],
  },
  {
    name: '2400-02-29 is a leap day because 2400 is divisible by 400',
    source: '2400-02-29',
    tokens: [{ tag: 'date', text: '2400-02-29', start: 0, end: 10 }],
    expected: { tag: 'date', year: 2400, month: 2, day: 29 },
    diagnostics: [],
  },
  {
    name: '0000-01-01 diagnoses the year and defaults to 0001-01-01',
    source: '0000-01-01',
    tokens: [{ tag: 'date', text: '0000-01-01', start: 0, end: 10 }],
    expected: { tag: 'date', year: 1, month: 1, day: 1 },
    diagnostics: [atomError('date_invalid_year', DATE_INVALID_YEAR_MESSAGE, 0, 10)],
  },
  {
    name: '2026-13-01 diagnoses the month and defaults to 0001-01-01',
    source: '2026-13-01',
    tokens: [{ tag: 'date', text: '2026-13-01', start: 0, end: 10 }],
    expected: { tag: 'date', year: 1, month: 1, day: 1 },
    diagnostics: [atomError('date_invalid_month', DATE_INVALID_MONTH_MESSAGE, 0, 10)],
  },
  {
    name: '2026-02-30 diagnoses the day and defaults to 0001-01-01',
    source: '2026-02-30',
    tokens: [{ tag: 'date', text: '2026-02-30', start: 0, end: 10 }],
    expected: { tag: 'date', year: 1, month: 1, day: 1 },
    diagnostics: [atomError('date_invalid_day', DATE_INVALID_DAY_MESSAGE, 0, 10)],
  },
  {
    name: '1900-02-29 diagnoses the day: 1900 is not a leap year',
    source: '1900-02-29',
    tokens: [{ tag: 'date', text: '1900-02-29', start: 0, end: 10 }],
    expected: { tag: 'date', year: 1, month: 1, day: 1 },
    diagnostics: [atomError('date_invalid_day', DATE_INVALID_DAY_MESSAGE, 0, 10)],
  },
  {
    name: '2023-02-29 diagnoses the day in a non-leap year',
    source: '2023-02-29',
    tokens: [{ tag: 'date', text: '2023-02-29', start: 0, end: 10 }],
    expected: { tag: 'date', year: 1, month: 1, day: 1 },
    diagnostics: [atomError('date_invalid_day', DATE_INVALID_DAY_MESSAGE, 0, 10)],
  },
  {
    name: '1900-1899 is not a date: 1900 then -1899',
    source: '1900-1899',
    tokens: [
      { tag: 'number', text: '1900', start: 0, end: 4 },
      { tag: 'number', text: '-1899', start: 4, end: 9 },
    ],
    expected: { tag: 'number', value: 1900, unit: null, integer: 1900n },
    diagnostics: [],
  },
  {
    name: '2026-5-19 is not a date: no zero-padded month or day',
    source: '2026-5-19',
    tokens: [
      { tag: 'number', text: '2026', start: 0, end: 4 },
      { tag: 'number', text: '-5', start: 4, end: 6 },
      { tag: 'number', text: '-19', start: 6, end: 9 },
    ],
    expected: { tag: 'number', value: 2026, unit: null, integer: 2026n },
    diagnostics: [],
  },
  {
    name: '10000-01-01 is not a date: a five-digit year is a number',
    source: '10000-01-01',
    tokens: [
      { tag: 'number', text: '10000', start: 0, end: 5 },
      { tag: 'number', text: '-01', start: 5, end: 8 },
      { tag: 'number', text: '-01', start: 8, end: 11 },
    ],
    expected: { tag: 'number', value: 10000, unit: null, integer: 10000n },
    diagnostics: [],
  },
  {
    name: '10000-01-01 leaves a negative zero-padded component',
    source: '10000-01-01',
    tokens: [
      { tag: 'number', text: '10000', start: 0, end: 5 },
      { tag: 'number', text: '-01', start: 5, end: 8 },
      { tag: 'number', text: '-01', start: 8, end: 11 },
    ],
    tokenIndex: 1,
    expected: { tag: 'number', value: -1, unit: null, integer: -1n },
    diagnostics: [],
  },
  {
    name: '2026-05-19x is a date followed by a symbol',
    source: '2026-05-19x',
    tokens: [
      { tag: 'date', text: '2026-05-19', start: 0, end: 10 },
      { tag: 'symbol', text: 'x', start: 10, end: 11 },
    ],
    expected: { tag: 'date', year: 2026, month: 5, day: 19 },
    diagnostics: [],
  },
];

export const timeCases: readonly AtomCase[] = [
  {
    name: '00:00:00 is the minimum time',
    source: '00:00:00',
    tokens: [{ tag: 'time', text: '00:00:00', start: 0, end: 8 }],
    expected: { tag: 'time', hour: 0, minute: 0, second: 0, millisecond: 0 },
    diagnostics: [],
  },
  {
    name: '23:59:59.999 is the maximum time',
    source: '23:59:59.999',
    tokens: [{ tag: 'time', text: '23:59:59.999', start: 0, end: 12 }],
    expected: { tag: 'time', hour: 23, minute: 59, second: 59, millisecond: 999 },
    diagnostics: [],
  },
  {
    name: '12:34:56.000 keeps its zero milliseconds',
    source: '12:34:56.000',
    tokens: [{ tag: 'time', text: '12:34:56.000', start: 0, end: 12 }],
    expected: { tag: 'time', hour: 12, minute: 34, second: 56, millisecond: 0 },
    diagnostics: [],
  },
  {
    name: '24:00:00 diagnoses the hour and defaults to 00:00:00.000',
    source: '24:00:00',
    tokens: [{ tag: 'time', text: '24:00:00', start: 0, end: 8 }],
    expected: { tag: 'time', hour: 0, minute: 0, second: 0, millisecond: 0 },
    diagnostics: [atomError('time_invalid_hour', TIME_INVALID_HOUR_MESSAGE, 0, 8)],
  },
  {
    name: '12:60:00 diagnoses the minute and defaults to 00:00:00.000',
    source: '12:60:00',
    tokens: [{ tag: 'time', text: '12:60:00', start: 0, end: 8 }],
    expected: { tag: 'time', hour: 0, minute: 0, second: 0, millisecond: 0 },
    diagnostics: [atomError('time_invalid_minute', TIME_INVALID_MINUTE_MESSAGE, 0, 8)],
  },
  {
    name: '12:34:60 diagnoses the second and defaults to 00:00:00.000',
    source: '12:34:60',
    tokens: [{ tag: 'time', text: '12:34:60', start: 0, end: 8 }],
    expected: { tag: 'time', hour: 0, minute: 0, second: 0, millisecond: 0 },
    diagnostics: [atomError('time_invalid_second', TIME_INVALID_SECOND_MESSAGE, 0, 8)],
  },
  {
    name: '12:34 is a number then a keyword, not a time',
    source: '12:34',
    tokens: [
      { tag: 'number', text: '12', start: 0, end: 2 },
      { tag: 'keyword', text: ':34', start: 2, end: 5 },
    ],
    expected: { tag: 'number', value: 12, unit: null, integer: 12n },
    diagnostics: [],
  },
  {
    name: '12:34:56.1 is an 8-char time then a symbol, not one time',
    source: '12:34:56.1',
    tokens: [
      { tag: 'time', text: '12:34:56', start: 0, end: 8 },
      { tag: 'symbol', text: '.1', start: 8, end: 10 },
    ],
    expected: { tag: 'time', hour: 12, minute: 34, second: 56, millisecond: 0 },
    diagnostics: [],
  },
  {
    name: '123:45:67 is a number then two keywords, not a time',
    source: '123:45:67',
    tokens: [
      { tag: 'number', text: '123', start: 0, end: 3 },
      { tag: 'keyword', text: ':45', start: 3, end: 6 },
      { tag: 'keyword', text: ':67', start: 6, end: 9 },
    ],
    expected: { tag: 'number', value: 123, unit: null, integer: 123n },
    diagnostics: [],
  },
];

export const atomCases: readonly AtomCase[] = [
  {
    name: ':true is a keyword, not the boolean literal',
    source: ':true',
    tokens: [{ tag: 'keyword', text: ':true', start: 0, end: 5 }],
    expected: { tag: 'keyword', value: 'true' },
    diagnostics: [],
  },
  {
    name: '::foo leaves :foo as the keyword after one invalid colon',
    source: '::foo',
    tokens: [
      { tag: 'invalid', text: ':', start: 0, end: 1 },
      { tag: 'keyword', text: ':foo', start: 1, end: 5 },
    ],
    tokenIndex: 1,
    expected: { tag: 'keyword', value: 'foo' },
    diagnostics: [],
  },
  {
    name: ':a#b keeps a as a keyword and b as a symbol',
    source: ':a#b',
    tokens: [
      { tag: 'keyword', text: ':a', start: 0, end: 2 },
      { tag: 'invalid', text: '#', start: 2, end: 3 },
      { tag: 'symbol', text: 'b', start: 3, end: 4 },
    ],
    expected: { tag: 'keyword', value: 'a' },
    diagnostics: [],
  },
  {
    name: ':a#b leaves b as a symbol',
    source: ':a#b',
    tokens: [
      { tag: 'keyword', text: ':a', start: 0, end: 2 },
      { tag: 'invalid', text: '#', start: 2, end: 3 },
      { tag: 'symbol', text: 'b', start: 3, end: 4 },
    ],
    tokenIndex: 2,
    expected: { tag: 'symbol', value: 'b' },
    diagnostics: [],
  },
  {
    name: 'a#b is one symbol, because # continues a symbol body',
    source: 'a#b',
    tokens: [{ tag: 'symbol', text: 'a#b', start: 0, end: 3 }],
    expected: { tag: 'symbol', value: 'a#b' },
    diagnostics: [],
  },
  {
    name: 'C#4 is one symbol',
    source: 'C#4',
    tokens: [{ tag: 'symbol', text: 'C#4', start: 0, end: 3 }],
    expected: { tag: 'symbol', value: 'C#4' },
    diagnostics: [],
  },
  {
    name: '$foo is a symbol',
    source: '$foo',
    tokens: [{ tag: 'symbol', text: '$foo', start: 0, end: 4 }],
    expected: { tag: 'symbol', value: '$foo' },
    diagnostics: [],
  },
  {
    name: '@bar is a symbol',
    source: '@bar',
    tokens: [{ tag: 'symbol', text: '@bar', start: 0, end: 4 }],
    expected: { tag: 'symbol', value: '@bar' },
    diagnostics: [],
  },
  {
    name: 'true is the boolean literal',
    source: 'true',
    tokens: [{ tag: 'true_lit', text: 'true', start: 0, end: 4 }],
    expected: { tag: 'boolean', value: true },
    diagnostics: [],
  },
  {
    name: 'false is the boolean literal',
    source: 'false',
    tokens: [{ tag: 'false_lit', text: 'false', start: 0, end: 5 }],
    expected: { tag: 'boolean', value: false },
    diagnostics: [],
  },
  {
    name: 'nil is the nil literal',
    source: 'nil',
    tokens: [{ tag: 'nil_lit', text: 'nil', start: 0, end: 3 }],
    expected: { tag: 'nil' },
    diagnostics: [],
  },
  {
    name: 'truex is a symbol, not the true literal plus x',
    source: 'truex',
    tokens: [{ tag: 'symbol', text: 'truex', start: 0, end: 5 }],
    expected: { tag: 'symbol', value: 'truex' },
    diagnostics: [],
  },
  {
    name: 'nilx is a symbol, not the nil literal plus x',
    source: 'nilx',
    tokens: [{ tag: 'symbol', text: 'nilx', start: 0, end: 4 }],
    expected: { tag: 'symbol', value: 'nilx' },
    diagnostics: [],
  },
  {
    name: 'TRUE is a symbol; reserved literals are lowercase only',
    source: 'TRUE',
    tokens: [{ tag: 'symbol', text: 'TRUE', start: 0, end: 4 }],
    expected: { tag: 'symbol', value: 'TRUE' },
    diagnostics: [],
  },
  {
    name: ':nil is a keyword, not the nil literal',
    source: ':nil',
    tokens: [{ tag: 'keyword', text: ':nil', start: 0, end: 4 }],
    expected: { tag: 'keyword', value: 'nil' },
    diagnostics: [],
  },
  {
    name: ':1 is a keyword body, because digits continue a keyword',
    source: ':1',
    tokens: [{ tag: 'keyword', text: ':1', start: 0, end: 2 }],
    expected: { tag: 'keyword', value: '1' },
    diagnostics: [],
  },
  {
    name: '123:45:67 leaves :45 as a keyword',
    source: '123:45:67',
    tokens: [
      { tag: 'number', text: '123', start: 0, end: 3 },
      { tag: 'keyword', text: ':45', start: 3, end: 6 },
      { tag: 'keyword', text: ':67', start: 6, end: 9 },
    ],
    tokenIndex: 1,
    expected: { tag: 'keyword', value: '45' },
    diagnostics: [],
  },
  {
    name: '123:45:67 leaves :67 as a keyword',
    source: '123:45:67',
    tokens: [
      { tag: 'number', text: '123', start: 0, end: 3 },
      { tag: 'keyword', text: ':45', start: 3, end: 6 },
      { tag: 'keyword', text: ':67', start: 6, end: 9 },
    ],
    tokenIndex: 2,
    expected: { tag: 'keyword', value: '67' },
    diagnostics: [],
  },
  {
    name: '+5 is a symbol; the lexer only splits - into a number',
    source: '+5',
    tokens: [{ tag: 'symbol', text: '+5', start: 0, end: 2 }],
    expected: { tag: 'symbol', value: '+5' },
    diagnostics: [],
  },
  {
    name: '.5 is a symbol; a number must start with a digit or -digit',
    source: '.5',
    tokens: [{ tag: 'symbol', text: '.5', start: 0, end: 2 }],
    expected: { tag: 'symbol', value: '.5' },
    diagnostics: [],
  },
  {
    name: '- is a symbol, not an empty number',
    source: '-',
    tokens: [{ tag: 'symbol', text: '-', start: 0, end: 1 }],
    expected: { tag: 'symbol', value: '-' },
    diagnostics: [],
  },
  {
    name: '-.5 is a symbol, not negative one half',
    source: '-.5',
    tokens: [{ tag: 'symbol', text: '-.5', start: 0, end: 3 }],
    expected: { tag: 'symbol', value: '-.5' },
    diagnostics: [],
  },
  {
    name: '--5 is one symbol',
    source: '--5',
    tokens: [{ tag: 'symbol', text: '--5', start: 0, end: 3 }],
    expected: { tag: 'symbol', value: '--5' },
    diagnostics: [],
  },
  {
    name: '%50 is a symbol; % is a unit only after a number',
    source: '%50',
    tokens: [{ tag: 'symbol', text: '%50', start: 0, end: 3 }],
    expected: { tag: 'symbol', value: '%50' },
    diagnostics: [],
  },
  {
    name: '1..2 leaves .2 as a symbol',
    source: '1..2',
    tokens: [
      { tag: 'number', text: '1.', start: 0, end: 2 },
      { tag: 'symbol', text: '.2', start: 2, end: 4 },
    ],
    tokenIndex: 1,
    expected: { tag: 'symbol', value: '.2' },
    diagnostics: [],
  },
  {
    name: '1.2.3 leaves .3 as a symbol',
    source: '1.2.3',
    tokens: [
      { tag: 'number', text: '1.2', start: 0, end: 3 },
      { tag: 'symbol', text: '.3', start: 3, end: 5 },
    ],
    tokenIndex: 1,
    expected: { tag: 'symbol', value: '.3' },
    diagnostics: [],
  },
  {
    name: 'a non-ASCII string is one string atom with a byte span',
    source: '"héllo ☀️"',
    tokens: [{ tag: 'string', text: '"héllo ☀️"', start: 0, end: 15 }],
    expected: { tag: 'string', value: 'héllo ☀️' },
    diagnostics: [],
  },
  {
    name: 'a raw string atom carries its verbatim body',
    source: '"""raw"""',
    tokens: [{ tag: 'raw_string', text: '"""raw"""', start: 0, end: 9 }],
    expected: { tag: 'string', value: 'raw' },
    diagnostics: [],
  },
];

/**
 * Spellings where a broader number regex would find a literal but the engine
 * emits an invalid token instead. Every token listed as `invalid` must not
 * become an atom; any symbol token in the stream still does.
 */
export const atomRejectCases: readonly LexicalCase[] = [
  {
    name: '0x without a digit is an invalid prefix',
    source: '0x',
    tokens: [{ tag: 'invalid', text: '0x', start: 0, end: 2 }],
  },
  {
    name: '0x_F is an invalid prefix then the symbol _F',
    source: '0x_F',
    tokens: [
      { tag: 'invalid', text: '0x', start: 0, end: 2 },
      { tag: 'symbol', text: '_F', start: 2, end: 4 },
    ],
  },
  {
    name: '0xGG is an invalid prefix then the symbol GG',
    source: '0xGG',
    tokens: [
      { tag: 'invalid', text: '0x', start: 0, end: 2 },
      { tag: 'symbol', text: 'GG', start: 2, end: 4 },
    ],
  },
  {
    name: '-0x without a digit is one invalid token',
    source: '-0x',
    tokens: [{ tag: 'invalid', text: '-0x', start: 0, end: 3 }],
  },
  {
    name: '1e+ without an exponent digit is one invalid token',
    source: '1e+',
    tokens: [{ tag: 'invalid', text: '1e+', start: 0, end: 3 }],
  },
  {
    name: 'a bare colon is one invalid token',
    source: ':',
    tokens: [{ tag: 'invalid', text: ':', start: 0, end: 1 }],
  },
];
