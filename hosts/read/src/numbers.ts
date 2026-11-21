// Exact numeric classification for the reader.
//
// Ported from `Parser.makeLeaf` / `makeHexLeaf` / `splitNumberAndUnit`. The
// rule that matters is bigint first: an integer-shaped literal is accumulated
// exactly and only then gets its f64 `value` view, so i64.max, i64.min and
// u64.max never round on the way in. True overflow out of
// [i64.min, u64.max] emits `number_overflow_exact_integer` and falls back to
// the f64 value, exactly as the engine does — this module does not invent a
// bigger integer type.
//
// The engine has four tree tags; the reader has one `NumberNode`.
//   * `integer` non-null  → engine `number_i64` (≤ i64.max) or
//     `number_u64` (i64.max < v ≤ u64.max).
//   * `unit` non-null     → engine `number_with_unit`; `integer` is always
//     null because units are arithmetic-shaped and have no exact tag.
//   * both null           → engine `number` (f64): `1e3`, `1.0`, `1.5e-10`,
//     and the overflow fallback.
//
// Hex is an integer and nothing else. It is recognised by re-reading the
// token's bytes, not by trusting lexer state: `0xFF` is not the value 0 with
// unit `xFF`. Hex never carries a unit (`0xFFms` is a hex number followed by
// the symbol `ms`) and never parses as a decimal.

import type { ReadDiagnostic } from './diagnostics.ts';
import type { Token } from './lexer.ts';
import type { NumberNode } from './nodes.ts';
import { decodeRange } from './source.ts';

const BYTE_PERCENT = 0x25;
const BYTE_PLUS = 0x2b;
const BYTE_MINUS = 0x2d;
const BYTE_DOT = 0x2e;
const BYTE_0 = 0x30;
const BYTE_9 = 0x39;
const BYTE_UPPER_A = 0x41;
const BYTE_UPPER_E = 0x45;
const BYTE_UPPER_F = 0x46;
const BYTE_UPPER_X = 0x58;
const BYTE_UNDERSCORE = 0x5f;
const BYTE_LOWER_A = 0x61;
const BYTE_LOWER_E = 0x65;
const BYTE_LOWER_F = 0x66;
const BYTE_LOWER_X = 0x78;

/** Inclusive i64 lower bound, as a bigint. */
const I64_MIN = -(2n ** 63n);
/** Inclusive u64 upper bound, as a bigint. */
const U64_MAX = 2n ** 64n - 1n;

const NUMBER_OVERFLOW_MESSAGE = 'integer literal exceeds u64 range; storing as approximate f64';

/** One classified number token: the public node plus any engine diagnostic. */
export interface NumberAtom {
  readonly node: NumberNode;
  readonly diagnostics: readonly ReadDiagnostic[];
}

interface NumberSplit {
  readonly numericStart: number;
  readonly numericEnd: number;
  readonly unitStart: number;
  readonly unitEnd: number;
}

interface HexLexeme {
  readonly negative: boolean;
  readonly digitsStart: number;
  readonly digitsEnd: number;
}

function isDigit(byte: number): boolean {
  return byte >= BYTE_0 && byte <= BYTE_9;
}

function hexDigitValue(byte: number): number | null {
  if (isDigit(byte)) return byte - BYTE_0;
  if (byte >= BYTE_LOWER_A && byte <= BYTE_LOWER_F) return byte - BYTE_LOWER_A + 10;
  if (byte >= BYTE_UPPER_A && byte <= BYTE_UPPER_F) return byte - BYTE_UPPER_A + 10;
  return null;
}

/** True when a numeric lexeme is integer-shaped (no `.`, `e`, or `E`). */
function hasFloatShape(cleaned: string): boolean {
  return cleaned.includes('.') || cleaned.includes('e') || cleaned.includes('E');
}

function stripUnderscores(text: string): string {
  return text.replaceAll('_', '');
}

/**
 * Walk a `.number` token and split it into numeric and unit byte ranges.
 *
 * Mirrors `Parser.splitNumberAndUnit`: `e`/`E` is an exponent only when a
 * digit (optionally after a sign) follows; otherwise it starts the unit.
 * The unit is a single `%` or the remaining run of bytes (letters, and
 * `-letter` pairs from the lexer's unit state). Pre: a lexer-produced
 * `.number` token; post: `numericStart == start` and the ranges tile the
 * token in order.
 */
function splitNumberAndUnit(bytes: Uint8Array, start: number, end: number): NumberSplit {
  let index = start;
  if (index < end && bytes[index] === BYTE_MINUS) index += 1;
  while (index < end) {
    const byte = bytes[index] ?? 0;
    if (!isDigit(byte) && byte !== BYTE_UNDERSCORE) break;
    index += 1;
  }
  if (index < end && bytes[index] === BYTE_DOT) {
    index += 1;
    while (index < end) {
      const byte = bytes[index] ?? 0;
      if (!isDigit(byte) && byte !== BYTE_UNDERSCORE) break;
      index += 1;
    }
  }
  if (index < end && (bytes[index] === BYTE_LOWER_E || bytes[index] === BYTE_UPPER_E)) {
    let probe = index + 1;
    if (probe < end && (bytes[probe] === BYTE_PLUS || bytes[probe] === BYTE_MINUS)) {
      probe += 1;
    }
    if (probe < end && isDigit(bytes[probe] ?? 0)) {
      index = probe;
      while (index < end) {
        const byte = bytes[index] ?? 0;
        if (!isDigit(byte) && byte !== BYTE_UNDERSCORE) break;
        index += 1;
      }
    }
  }
  if (index < end && bytes[index] === BYTE_PERCENT) {
    return {
      numericStart: start,
      numericEnd: index,
      unitStart: index,
      unitEnd: index + 1,
    };
  }
  return { numericStart: start, numericEnd: index, unitStart: index, unitEnd: end };
}

/**
 * Recognise `[-] 0 (x|X) hex-digit …`. Returns `null` for every other shape,
 * including a decimal that merely starts with `0`.
 */
function splitHexLexeme(bytes: Uint8Array, start: number, end: number): HexLexeme | null {
  let index = start;
  const negative = index < end && bytes[index] === BYTE_MINUS;
  if (negative) index += 1;
  // `0x` plus at least one further byte.
  if (end - index < 3) return null;
  if (bytes[index] !== BYTE_0) return null;
  const prefix = bytes[index + 1];
  if (prefix !== BYTE_LOWER_X && prefix !== BYTE_UPPER_X) return null;
  return { negative, digitsStart: index + 2, digitsEnd: end };
}

/**
 * Accumulate an underscore-free decimal integer exactly. Returns `null` only
 * for a byte outside `[-]?[0-9]+`, which a lexer-produced integer-shaped
 * token cannot contain; callers treat that as an invalid literal.
 */
function accumulateDecimal(text: string): bigint | null {
  let index = 0;
  const negative = text.startsWith('-');
  if (negative) index += 1;
  let value = 0n;
  for (; index < text.length; index += 1) {
    const byte = text.charCodeAt(index);
    if (!isDigit(byte)) return null;
    value = value * 10n + BigInt(byte - BYTE_0);
  }
  return negative ? -value : value;
}

/** Accumulate a hex digit run, skipping `_`, exactly like `renderHex`. */
function accumulateHex(bytes: Uint8Array, start: number, end: number): bigint | null {
  let value = 0n;
  for (let index = start; index < end; index += 1) {
    const byte = bytes[index] ?? 0;
    if (byte === BYTE_UNDERSCORE) continue;
    const digit = hexDigitValue(byte);
    if (digit === null) return null;
    value = value * 16n + BigInt(digit);
  }
  return value;
}

function parseF64(text: string): number | null {
  const value = Number(text);
  return Number.isNaN(value) ? null : value;
}

function overflowDiagnostic(
  span: { readonly start: number; readonly end: number },
  path: readonly string[],
): ReadDiagnostic {
  return {
    code: 'number_overflow_exact_integer',
    severity: 'err',
    message: NUMBER_OVERFLOW_MESSAGE,
    span,
    path,
  };
}

function invalidNumberDiagnostic(
  span: { readonly start: number; readonly end: number },
  path: readonly string[],
): ReadDiagnostic {
  return {
    code: 'unspecified',
    severity: 'err',
    message: 'invalid number literal',
    span,
    path,
  };
}

function classifyHex(
  bytes: Uint8Array,
  hex: HexLexeme,
  span: { readonly start: number; readonly end: number },
  path: readonly string[],
): NumberAtom {
  // A lexer-produced hex token always has at least one valid hex digit, so a
  // null accumulation is unreachable; keeping the zero fallback matches the
  // engine's defensive InvalidCharacter path instead of throwing.
  const magnitude = accumulateHex(bytes, hex.digitsStart, hex.digitsEnd) ?? 0n;
  const exact = hex.negative ? -magnitude : magnitude;
  const value = Number(exact);
  if (exact >= I64_MIN && exact <= U64_MAX) {
    return {
      node: { tag: 'number', span, value, unit: null, integer: exact },
      diagnostics: [],
    };
  }
  return {
    node: { tag: 'number', span, value, unit: null, integer: null },
    diagnostics: [overflowDiagnostic(span, path)],
  };
}

/**
 * Classify one `.number` token exactly.
 *
 * Pre: `token.tag === 'number'` (a lexer-produced number token, so at least
 * one digit is present). Post: `node.span` is the token's byte span;
 * `integer` is non-null iff the literal is integer-shaped, unitless, and
 * inside `[i64.min, u64.max]`. Complexity O(token length); no allocation
 * proportional to the numeric magnitude beyond the bigint itself.
 */
export function classifyNumber(
  bytes: Uint8Array,
  token: Token,
  path: readonly string[] = [],
): NumberAtom {
  if (token.tag !== 'number') {
    throw new TypeError(`classifyNumber expects a number token, got ${token.tag}`);
  }
  const span = { start: token.start, end: token.end };

  const hex = splitHexLexeme(bytes, token.start, token.end);
  if (hex !== null) return classifyHex(bytes, hex, span, path);

  const split = splitNumberAndUnit(bytes, token.start, token.end);
  const numeric = stripUnderscores(decodeRange(bytes, split.numericStart, split.numericEnd));

  if (split.unitEnd > split.unitStart) {
    const unit = decodeRange(bytes, split.unitStart, split.unitEnd);
    const value = parseF64(numeric);
    if (value === null) {
      return {
        node: { tag: 'number', span, value: 0, unit: null, integer: null },
        diagnostics: [invalidNumberDiagnostic(span, path)],
      };
    }
    return { node: { tag: 'number', span, value, unit, integer: null }, diagnostics: [] };
  }

  if (!hasFloatShape(numeric)) {
    const exact = accumulateDecimal(numeric);
    if (exact === null) {
      return {
        node: { tag: 'number', span, value: 0, unit: null, integer: null },
        diagnostics: [invalidNumberDiagnostic(span, path)],
      };
    }
    const value = Number(numeric);
    if (exact >= I64_MIN && exact <= U64_MAX) {
      return { node: { tag: 'number', span, value, unit: null, integer: exact }, diagnostics: [] };
    }
    return {
      node: { tag: 'number', span, value, unit: null, integer: null },
      diagnostics: [overflowDiagnostic(span, path)],
    };
  }

  const value = parseF64(numeric);
  if (value === null) {
    return {
      node: { tag: 'number', span, value: 0, unit: null, integer: null },
      diagnostics: [invalidNumberDiagnostic(span, path)],
    };
  }
  return { node: { tag: 'number', span, value, unit: null, integer: null }, diagnostics: [] };
}
