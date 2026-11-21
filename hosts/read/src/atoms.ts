// Leaf-atom classification for the reader.
//
// The Task 4 parser calls `makeAtom` for every value token and owns frame
// structure, pairing, and recovery; this module owns only what one token
// means by itself. The split mirrors `Parser.makeLeaf`:
//
//   * numbers  → `numbers.classifyNumber` (exact bigint, unit, overflow)
//   * dates    → strict `YYYY-MM-DD`, validated like `Date.init`; a bad
//                component emits the engine's `date_invalid_*` diagnostic and
//                still returns a node defaulted to `0001-01-01`
//   * times    → strict `HH:MM:SS[.fff]`, validated like `Time.init`; a bad
//                component emits `time_invalid_*` and defaults to
//                `00:00:00.000`
//   * strings  → `strings.decodeStringValue` (raw bodies verbatim, escapes
//                `n t r " \ 0`, unknown escapes diagnosed)
//   * symbols, keywords, `true`, `false`, `nil` → their literal node
//
// `null` means "not a leaf": delimiters, comments, invalid bytes, and eof are
// the parser's business, not the atom classifier's. Diagnostics carry the
// caller's semantic path unchanged, because only the parser knows where the
// token sits in a frame.

import type { ReadDiagnostic } from './diagnostics.ts';
import type { Token } from './lexer.ts';
import type { Node } from './nodes.ts';
import { classifyNumber } from './numbers.ts';
import { decodeRange } from './source.ts';
import { decodeStringValue } from './strings.ts';

const BYTE_0 = 0x30;

const DATE_INVALID_YEAR_MESSAGE = 'date year out of range (1..9999)';
const DATE_INVALID_MONTH_MESSAGE = 'date month out of range (1..12)';
const DATE_INVALID_DAY_MESSAGE = 'date day out of range for the given year and month';
const TIME_INVALID_HOUR_MESSAGE = 'time hour out of range (0..23)';
const TIME_INVALID_MINUTE_MESSAGE = 'time minute out of range (0..59)';
const TIME_INVALID_SECOND_MESSAGE = 'time second out of range (0..59)';

const DAYS_IN_MONTH: readonly number[] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

/** One classified leaf token: the public node plus any engine diagnostics. */
export interface AtomResult {
  readonly node: Node;
  readonly diagnostics: readonly ReadDiagnostic[];
}

function isLeapYear(year: number): boolean {
  return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
}

function daysInMonth(year: number, month: number): number {
  if (month === 2 && isLeapYear(year)) return 29;
  return DAYS_IN_MONTH[month - 1] ?? 0;
}

/** ASCII digit value at an absolute byte offset (lexer guarantees 0..9). */
function digitAt(bytes: Uint8Array, at: number): number {
  return (bytes[at] ?? 0) - BYTE_0;
}

function makeDateAtom(bytes: Uint8Array, token: Token, path: readonly string[]): AtomResult {
  const span = { start: token.start, end: token.end };
  const start = token.start;
  const year =
    digitAt(bytes, start) * 1000 +
    digitAt(bytes, start + 1) * 100 +
    digitAt(bytes, start + 2) * 10 +
    digitAt(bytes, start + 3);
  const month = digitAt(bytes, start + 5) * 10 + digitAt(bytes, start + 6);
  const day = digitAt(bytes, start + 8) * 10 + digitAt(bytes, start + 9);

  let code: string | null = null;
  let message = '';
  if (year < 1 || year > 9999) {
    code = 'date_invalid_year';
    message = DATE_INVALID_YEAR_MESSAGE;
  } else if (month < 1 || month > 12) {
    code = 'date_invalid_month';
    message = DATE_INVALID_MONTH_MESSAGE;
  } else if (day < 1 || day > daysInMonth(year, month)) {
    code = 'date_invalid_day';
    message = DATE_INVALID_DAY_MESSAGE;
  }

  if (code !== null) {
    return {
      node: { tag: 'date', span, year: 1, month: 1, day: 1 },
      diagnostics: [{ code, severity: 'err', message, span, path }],
    };
  }
  return { node: { tag: 'date', span, year, month, day }, diagnostics: [] };
}

function makeTimeAtom(bytes: Uint8Array, token: Token, path: readonly string[]): AtomResult {
  const span = { start: token.start, end: token.end };
  const start = token.start;
  const hour = digitAt(bytes, start) * 10 + digitAt(bytes, start + 1);
  const minute = digitAt(bytes, start + 3) * 10 + digitAt(bytes, start + 4);
  const second = digitAt(bytes, start + 6) * 10 + digitAt(bytes, start + 7);
  // The lexer accepts `.fff` as exactly three digits, so 0..999 is a lexer
  // invariant and `InvalidMillisecond` is unreachable from a `time` token.
  const millisecond =
    token.end - token.start === 12
      ? digitAt(bytes, start + 9) * 100 +
        digitAt(bytes, start + 10) * 10 +
        digitAt(bytes, start + 11)
      : 0;

  let code: string | null = null;
  let message = '';
  if (hour > 23) {
    code = 'time_invalid_hour';
    message = TIME_INVALID_HOUR_MESSAGE;
  } else if (minute > 59) {
    code = 'time_invalid_minute';
    message = TIME_INVALID_MINUTE_MESSAGE;
  } else if (second > 59) {
    code = 'time_invalid_second';
    message = TIME_INVALID_SECOND_MESSAGE;
  }

  if (code !== null) {
    return {
      node: { tag: 'time', span, hour: 0, minute: 0, second: 0, millisecond: 0 },
      diagnostics: [{ code, severity: 'err', message, span, path }],
    };
  }
  return { node: { tag: 'time', span, hour, minute, second, millisecond }, diagnostics: [] };
}

/**
 * Classify one token as a leaf node, or return `null` when the token is not a
 * leaf (delimiter, comment, invalid byte, eof).
 *
 * Pre: `token` came from the reader's lexer. Post: a returned node's span is
 * exactly the token's byte span, and every diagnostic carries `path`.
 * Complexity O(token length).
 */
export function makeAtom(
  bytes: Uint8Array,
  token: Token,
  path: readonly string[] = [],
): AtomResult | null {
  const span = { start: token.start, end: token.end };
  switch (token.tag) {
    case 'number':
      return classifyNumber(bytes, token, path);
    case 'date':
      return makeDateAtom(bytes, token, path);
    case 'time':
      return makeTimeAtom(bytes, token, path);
    case 'string':
    case 'raw_string': {
      const decoded = decodeStringValue(bytes, token, path);
      return {
        node: { tag: 'string', span, value: decoded.value },
        diagnostics: decoded.diagnostics,
      };
    }
    case 'symbol':
      return {
        node: { tag: 'symbol', span, value: decodeRange(bytes, token.start, token.end) },
        diagnostics: [],
      };
    case 'keyword':
      return {
        node: {
          tag: 'keyword',
          span,
          value: decodeRange(bytes, token.start + 1, token.end),
        },
        diagnostics: [],
      };
    case 'true_lit':
      return { node: { tag: 'boolean', span, value: true }, diagnostics: [] };
    case 'false_lit':
      return { node: { tag: 'boolean', span, value: false }, diagnostics: [] };
    case 'nil_lit':
      return { node: { tag: 'nil', span }, diagnostics: [] };
    default:
      return null;
  }
}
