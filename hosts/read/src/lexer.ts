// Internal byte-oriented SJON lexer.
//
// A single-pass labeled state machine ported from `src/Lexer.zig`, not a
// regular-expression reader over JS characters. Input is the `TextEncoder`
// byte view from `source.ts`, so `start` / `end` are absolute UTF-8 byte
// offsets and every span stays correct after a non-ASCII node. Decoding is
// deliberately elsewhere: this module only classifies bytes.
//
// Invariants, mirrored from the Zig lexer:
//   * Never throws and never allocates a value: any unclassifiable byte is one
//     `.invalid` token; the parser owns diagnostics. `invalid` spans sometimes
//     cover more than the offending byte (`0x` prefix, `1e+`), exactly as the
//     engine does.
//   * The forward-only index only increases. `eof` is steady-state at
//     `start === end === bytes.length`.
//   * `end >= start` for every token.
//   * A leading UTF-8 BOM is skipped only at offset 0; the skipped bytes stay
//     part of every later offset, so spans remain absolute.
//   * A NUL byte is content unless the index has reached `bytes.length` — the
//     Zig source is sentinel-terminated, so the same rule separates a source
//     NUL from EOF. `byteAt()` reproduces that sentinel.
//
// State distinctions worth not "simplifying":
//   * `.block_pipe` refuses to consume a `|` that is not followed by `#`, so
//     `#| a | b |#` is one comment and block comments never nest: the first
//     `|#` closes (Zig `Lexer.zig:1341`).
//   * `.string_escape` rejects a NUL even mid-source; `.string_body` accepts a
//     NUL as content. `"\` + NUL is therefore an invalid token, then an invalid
//     NUL byte, then the tail as fresh tokens.
//   * `.raw_string_body` closes on three consecutive quotes and otherwise
//     treats every byte as content; `"` and `""` runs are body bytes, and the
//     close is greedy (`""""abc"""` has body `"abc`).
//   * `#` starts a block comment only at token start. Inside a symbol body it
//     is a continuation character (`C#4`); inside a keyword body it is not
//     (`:a#b` is keyword `:a`, invalid `#`, symbol `b`).
//   * Only `-` gets a number-vs-symbol split at `.start`; `+0` is one symbol.

/**
 * Token kinds, mirroring `Lexer.Token.Tag` (including the `_lit` suffix on the
 * reserved words, which is a lexer distinction, not a node tag).
 */
export type TokenTag =
  | 'lparen'
  | 'rparen'
  | 'lbracket'
  | 'rbracket'
  | 'keyword'
  | 'symbol'
  | 'number'
  | 'date'
  | 'time'
  | 'string'
  | 'raw_string'
  | 'true_lit'
  | 'false_lit'
  | 'nil_lit'
  | 'comment_line'
  | 'comment_block'
  | 'invalid'
  | 'eof';

/** One lexeme. `start` / `end` are absolute UTF-8 byte offsets. */
export interface Token {
  readonly tag: TokenTag;
  readonly start: number;
  readonly end: number;
}

const BYTE_NUL = 0x00;
const BYTE_TAB = 0x09;
const BYTE_LF = 0x0a;
const BYTE_CR = 0x0d;
const BYTE_SPACE = 0x20;
const BYTE_BANG = 0x21;
const BYTE_DQUOTE = 0x22;
const BYTE_HASH = 0x23;
const BYTE_DOLLAR = 0x24;
const BYTE_PERCENT = 0x25;
const BYTE_AMP = 0x26;
const BYTE_LPAREN = 0x28;
const BYTE_RPAREN = 0x29;
const BYTE_STAR = 0x2a;
const BYTE_PLUS = 0x2b;
const BYTE_MINUS = 0x2d;
const BYTE_DOT = 0x2e;
const BYTE_SLASH = 0x2f;
const BYTE_0 = 0x30;
const BYTE_9 = 0x39;
const BYTE_COLON = 0x3a;
const BYTE_SEMI = 0x3b;
const BYTE_LT = 0x3c;
const BYTE_EQ = 0x3d;
const BYTE_GT = 0x3e;
const BYTE_QUESTION = 0x3f;
const BYTE_AT = 0x40;
const BYTE_UPPER_A = 0x41;
const BYTE_UPPER_E = 0x45;
const BYTE_UPPER_F = 0x46;
const BYTE_UPPER_X = 0x58;
const BYTE_UPPER_Z = 0x5a;
const BYTE_LBRACKET = 0x5b;
const BYTE_BACKSLASH = 0x5c;
const BYTE_RBRACKET = 0x5d;
const BYTE_CARET = 0x5e;
const BYTE_UNDERSCORE = 0x5f;
const BYTE_LOWER_A = 0x61;
const BYTE_LOWER_E = 0x65;
const BYTE_LOWER_F = 0x66;
const BYTE_LOWER_X = 0x78;
const BYTE_LOWER_Z = 0x7a;
const BYTE_PIPE = 0x7c;
const BYTE_TILDE = 0x7e;

const BYTE_BOM_0 = 0xef;
const BYTE_BOM_1 = 0xbb;
const BYTE_BOM_2 = 0xbf;

type State =
  | 'start'
  | 'minus'
  | 'number_int'
  | 'number_dot'
  | 'number_frac'
  | 'number_exp_sign'
  | 'number_exp_first_digit'
  | 'number_exp'
  | 'number_unit'
  | 'hex_first_digit'
  | 'hex_body'
  | 'string_body'
  | 'string_escape'
  | 'raw_string_body'
  | 'keyword_body'
  | 'symbol_body'
  | 'comment_line_body'
  | 'block_hash'
  | 'block_body'
  | 'block_pipe';

type TimeTailMatch = 'miss' | 'match8' | 'match12';

function isDigit(byte: number): boolean {
  return byte >= BYTE_0 && byte <= BYTE_9;
}

function isUpper(byte: number): boolean {
  return byte >= BYTE_UPPER_A && byte <= BYTE_UPPER_Z;
}

function isLower(byte: number): boolean {
  return byte >= BYTE_LOWER_A && byte <= BYTE_LOWER_Z;
}

function isLetter(byte: number): boolean {
  return isUpper(byte) || isLower(byte);
}

function isHexDigit(byte: number): boolean {
  return (
    isDigit(byte) ||
    (byte >= BYTE_LOWER_A && byte <= BYTE_LOWER_F) ||
    (byte >= BYTE_UPPER_A && byte <= BYTE_UPPER_F)
  );
}

/** The `.start` symbol-body starters: letters, `_`, and operator sigils. */
function isSymbolStart(byte: number): boolean {
  return (
    isLetter(byte) ||
    byte === BYTE_UNDERSCORE ||
    byte === BYTE_PLUS ||
    byte === BYTE_STAR ||
    byte === BYTE_SLASH ||
    byte === BYTE_LT ||
    byte === BYTE_GT ||
    byte === BYTE_EQ ||
    byte === BYTE_BANG ||
    byte === BYTE_QUESTION ||
    byte === BYTE_DOT ||
    byte === BYTE_PERCENT ||
    byte === BYTE_AMP ||
    byte === BYTE_PIPE ||
    byte === BYTE_CARET ||
    byte === BYTE_TILDE ||
    byte === BYTE_DOLLAR ||
    byte === BYTE_AT
  );
}

/** Keyword-body alphabet: the symbol starters plus digits and `-`, no `#`. */
function isKeywordBody(byte: number): boolean {
  return isSymbolStart(byte) || isDigit(byte) || byte === BYTE_MINUS;
}

/** Symbol-body alphabet: keyword body plus `#`. */
function isSymbolBody(byte: number): boolean {
  return isKeywordBody(byte) || byte === BYTE_HASH;
}

/** Read a byte, or the sentinel `0` past the end (mirrors `[:0]const u8`). */
function byteAt(bytes: Uint8Array, at: number): number {
  if (at >= bytes.length) return BYTE_NUL;
  return bytes[at] ?? BYTE_NUL;
}

/** True iff `bytes[start..end)` is exactly the ASCII spelling `text`. */
function spells(bytes: Uint8Array, start: number, end: number, text: string): boolean {
  if (end - start !== text.length) return false;
  for (let i = 0; i < text.length; i += 1) {
    if (bytes[start + i] !== text.charCodeAt(i)) return false;
  }
  return true;
}

/**
 * Date-literal lookahead from `.number_int`: exactly four ASCII digits before
 * the dash, then `-dd-dd`. The sentinel byte 0 fails `isDigit`, so peeking
 * past EOF is naturally a miss.
 */
function matchDateTail(bytes: Uint8Array, start: number, cursor: number): boolean {
  if (cursor - start !== 4) return false;
  for (let i = start; i < cursor; i += 1) {
    if (!isDigit(byteAt(bytes, i))) return false;
  }
  return (
    byteAt(bytes, cursor) === BYTE_MINUS &&
    isDigit(byteAt(bytes, cursor + 1)) &&
    isDigit(byteAt(bytes, cursor + 2)) &&
    byteAt(bytes, cursor + 3) === BYTE_MINUS &&
    isDigit(byteAt(bytes, cursor + 4)) &&
    isDigit(byteAt(bytes, cursor + 5))
  );
}

/**
 * Clock-time lookahead from `.number_int`: exactly two ASCII digits before the
 * colon, then `HH:MM:SS` with an optional all-or-nothing `.fff`. `.match8`
 * leaves a malformed or absent fractional component for the next pass.
 */
function matchTimeTail(bytes: Uint8Array, start: number, cursor: number): TimeTailMatch {
  if (cursor - start !== 2) return 'miss';
  if (!isDigit(byteAt(bytes, start))) return 'miss';
  if (!isDigit(byteAt(bytes, start + 1))) return 'miss';
  if (!isDigit(byteAt(bytes, cursor + 1))) return 'miss';
  if (!isDigit(byteAt(bytes, cursor + 2))) return 'miss';
  if (byteAt(bytes, cursor + 3) !== BYTE_COLON) return 'miss';
  if (!isDigit(byteAt(bytes, cursor + 4))) return 'miss';
  if (!isDigit(byteAt(bytes, cursor + 5))) return 'miss';
  if (byteAt(bytes, cursor + 6) === BYTE_DOT) {
    if (
      isDigit(byteAt(bytes, cursor + 7)) &&
      isDigit(byteAt(bytes, cursor + 8)) &&
      isDigit(byteAt(bytes, cursor + 9))
    ) {
      return 'match12';
    }
  }
  return 'match8';
}

/**
 * Hex prefix gate: the numeric portion so far must be exactly `0` or `-0`.
 * `10x`, `0_x`, and `0.5x` therefore keep their pre-hex unit reading.
 */
function isBareZero(bytes: Uint8Array, start: number, cursor: number): boolean {
  if (cursor - start === 1) return bytes[start] === BYTE_0;
  return cursor - start === 2 && bytes[start] === BYTE_MINUS && bytes[start + 1] === BYTE_0;
}

function classifySymbol(bytes: Uint8Array, start: number, end: number): TokenTag {
  if (spells(bytes, start, end, 'true')) return 'true_lit';
  if (spells(bytes, start, end, 'false')) return 'false_lit';
  if (spells(bytes, start, end, 'nil')) return 'nil_lit';
  return 'symbol';
}

/**
 * Byte cursor + token source for every later parser task.
 *
 * Construct once per source: `new Lexer(encodeSource(text))`. `next()` is safe
 * to call any number of times; after EOF it keeps returning a zero-width
 * `eof` at the byte length.
 */
export class Lexer {
  readonly bytes: Uint8Array;
  private index: number;

  constructor(source: Uint8Array) {
    this.bytes = source;
    const hasLeadingBom =
      source.length >= 3 &&
      source[0] === BYTE_BOM_0 &&
      source[1] === BYTE_BOM_1 &&
      source[2] === BYTE_BOM_2;
    this.index = hasLeadingBom ? 3 : 0;
  }

  /** Return the next token. Never throws; bad input becomes `.invalid`. */
  next(): Token {
    const bytes = this.bytes;
    let start = this.index;
    let state: State = 'start';

    while (true) {
      switch (state) {
        case 'start': {
          if (this.index === bytes.length) return this.finish('eof', start);
          const byte = this.at(0);

          if (byte === BYTE_NUL) {
            this.index += 1;
            return this.finish('invalid', start);
          }

          if (byte === BYTE_SPACE || byte === BYTE_TAB || byte === BYTE_CR || byte === BYTE_LF) {
            this.index += 1;
            start = this.index;
            continue;
          }

          switch (byte) {
            case BYTE_LPAREN:
              this.index += 1;
              return this.finish('lparen', start);
            case BYTE_RPAREN:
              this.index += 1;
              return this.finish('rparen', start);
            case BYTE_LBRACKET:
              this.index += 1;
              return this.finish('lbracket', start);
            case BYTE_RBRACKET:
              this.index += 1;
              return this.finish('rbracket', start);
            case BYTE_SEMI:
              this.index += 1;
              state = 'comment_line_body';
              continue;
            case BYTE_HASH:
              this.index += 1;
              state = 'block_hash';
              continue;
            case BYTE_DQUOTE: {
              this.index += 1;
              // `"""` opens raw mode; `""` and `"x"` stay escape-aware.
              if (this.at(0) === BYTE_DQUOTE && this.at(1) === BYTE_DQUOTE) {
                this.index += 2;
                state = 'raw_string_body';
                continue;
              }
              state = 'string_body';
              continue;
            }
            case BYTE_COLON:
              this.index += 1;
              state = 'keyword_body';
              continue;
            case BYTE_MINUS:
              this.index += 1;
              state = 'minus';
              continue;
            default:
              break;
          }

          if (isDigit(byte)) {
            this.index += 1;
            state = 'number_int';
            continue;
          }
          if (isSymbolStart(byte)) {
            this.index += 1;
            state = 'symbol_body';
            continue;
          }
          this.index += 1;
          return this.finish('invalid', start);
        }

        case 'minus': {
          if (isDigit(this.at(0))) {
            this.index += 1;
            state = 'number_int';
          } else {
            state = 'symbol_body';
          }
          continue;
        }

        case 'number_int': {
          const byte = this.at(0);
          if (isDigit(byte) || byte === BYTE_UNDERSCORE) {
            this.index += 1;
            continue;
          }
          if (byte === BYTE_DOT) {
            this.index += 1;
            state = 'number_dot';
            continue;
          }
          if (byte === BYTE_MINUS) {
            if (matchDateTail(bytes, start, this.index)) {
              this.index += 6;
              return this.finish('date', start);
            }
            return this.finish('number', start);
          }
          if (byte === BYTE_COLON) {
            switch (matchTimeTail(bytes, start, this.index)) {
              case 'match12':
                this.index += 10;
                return this.finish('time', start);
              case 'match8':
                this.index += 6;
                return this.finish('time', start);
              case 'miss':
                return this.finish('number', start);
            }
          }
          if (byte === BYTE_LOWER_E || byte === BYTE_UPPER_E) {
            const next = this.at(1);
            if (isDigit(next) || next === BYTE_PLUS || next === BYTE_MINUS) {
              this.index += 1;
              state = 'number_exp_sign';
            } else {
              state = 'number_unit';
            }
            continue;
          }
          if (byte === BYTE_LOWER_X || byte === BYTE_UPPER_X) {
            if (isBareZero(bytes, start, this.index)) {
              this.index += 1;
              state = 'hex_first_digit';
            } else {
              state = 'number_unit';
            }
            continue;
          }
          if (isLetter(byte)) {
            state = 'number_unit';
            continue;
          }
          if (byte === BYTE_PERCENT) {
            this.index += 1;
            return this.finish('number', start);
          }
          return this.finish('number', start);
        }

        case 'hex_first_digit': {
          if (isHexDigit(this.at(0))) {
            this.index += 1;
            state = 'hex_body';
            continue;
          }
          // `0x`, `0x_F`, `0xGG`: the token is just the prefix.
          return this.finish('invalid', start);
        }

        case 'hex_body': {
          const byte = this.at(0);
          if (isHexDigit(byte) || byte === BYTE_UNDERSCORE) {
            this.index += 1;
            continue;
          }
          return this.finish('number', start);
        }

        case 'number_dot': {
          const byte = this.at(0);
          if (isDigit(byte)) {
            this.index += 1;
            state = 'number_frac';
            continue;
          }
          if (isLetter(byte)) {
            state = 'number_unit';
            continue;
          }
          if (byte === BYTE_PERCENT) {
            this.index += 1;
            return this.finish('number', start);
          }
          return this.finish('number', start);
        }

        case 'number_frac': {
          const byte = this.at(0);
          if (isDigit(byte) || byte === BYTE_UNDERSCORE) {
            this.index += 1;
            continue;
          }
          if (byte === BYTE_LOWER_E || byte === BYTE_UPPER_E) {
            const next = this.at(1);
            if (isDigit(next) || next === BYTE_PLUS || next === BYTE_MINUS) {
              this.index += 1;
              state = 'number_exp_sign';
            } else {
              state = 'number_unit';
            }
            continue;
          }
          if (isLetter(byte)) {
            state = 'number_unit';
            continue;
          }
          if (byte === BYTE_PERCENT) {
            this.index += 1;
            return this.finish('number', start);
          }
          return this.finish('number', start);
        }

        case 'number_exp_sign': {
          const byte = this.at(0);
          if (byte === BYTE_PLUS || byte === BYTE_MINUS) {
            this.index += 1;
            state = 'number_exp_first_digit';
            continue;
          }
          if (isDigit(byte)) {
            state = 'number_exp';
            continue;
          }
          return this.finish('invalid', start);
        }

        case 'number_exp_first_digit': {
          if (isDigit(this.at(0))) {
            state = 'number_exp';
            continue;
          }
          return this.finish('invalid', start);
        }

        case 'number_exp': {
          const byte = this.at(0);
          if (isDigit(byte) || byte === BYTE_UNDERSCORE) {
            this.index += 1;
            continue;
          }
          if (isLetter(byte)) {
            state = 'number_unit';
            continue;
          }
          if (byte === BYTE_PERCENT) {
            this.index += 1;
            return this.finish('number', start);
          }
          return this.finish('number', start);
        }

        case 'number_unit': {
          const byte = this.at(0);
          if (isLetter(byte)) {
            this.index += 1;
            continue;
          }
          if (byte === BYTE_MINUS) {
            if (isLetter(this.at(1))) {
              this.index += 2;
              continue;
            }
            return this.finish('number', start);
          }
          return this.finish('number', start);
        }

        case 'string_body': {
          const byte = this.at(0);
          if (byte === BYTE_NUL) {
            if (this.index === bytes.length) return this.finish('invalid', start);
            this.index += 1;
            continue;
          }
          if (byte === BYTE_DQUOTE) {
            this.index += 1;
            return this.finish('string', start);
          }
          if (byte === BYTE_BACKSLASH) {
            this.index += 1;
            state = 'string_escape';
            continue;
          }
          this.index += 1;
          continue;
        }

        case 'string_escape': {
          // Any byte is accepted after `\` except the sentinel / a NUL: the
          // escape's meaning is the parser's business, not the lexer's.
          if (this.at(0) === BYTE_NUL) return this.finish('invalid', start);
          this.index += 1;
          state = 'string_body';
          continue;
        }

        case 'raw_string_body': {
          const byte = this.at(0);
          if (byte === BYTE_NUL) {
            if (this.index === bytes.length) return this.finish('invalid', start);
            this.index += 1;
            continue;
          }
          if (byte === BYTE_DQUOTE) {
            if (this.at(1) === BYTE_DQUOTE && this.at(2) === BYTE_DQUOTE) {
              this.index += 3;
              return this.finish('raw_string', start);
            }
            this.index += 1;
            continue;
          }
          this.index += 1;
          continue;
        }

        case 'keyword_body': {
          const byte = this.at(0);
          if (isKeywordBody(byte)) {
            this.index += 1;
            continue;
          }
          // A `:` with nothing after it is invalid rather than an empty key.
          if (this.index === start + 1) return this.finish('invalid', start);
          return this.finish('keyword', start);
        }

        case 'symbol_body': {
          if (isSymbolBody(this.at(0))) {
            this.index += 1;
            continue;
          }
          return this.finish(classifySymbol(bytes, start, this.index), start);
        }

        case 'comment_line_body': {
          const byte = this.at(0);
          if (byte === BYTE_NUL) {
            if (this.index === bytes.length) return this.finish('comment_line', start);
            this.index += 1;
            continue;
          }
          if (byte === BYTE_LF) {
            // The newline belongs to whitespace, not to the comment token.
            return this.finish('comment_line', start);
          }
          this.index += 1;
          continue;
        }

        case 'block_hash': {
          if (this.at(0) === BYTE_PIPE) {
            this.index += 1;
            state = 'block_body';
            continue;
          }
          return this.finish('invalid', start);
        }

        case 'block_body': {
          const byte = this.at(0);
          if (byte === BYTE_NUL) {
            if (this.index === bytes.length) return this.finish('invalid', start);
            this.index += 1;
            continue;
          }
          if (byte === BYTE_PIPE) {
            this.index += 1;
            state = 'block_pipe';
            continue;
          }
          this.index += 1;
          continue;
        }

        case 'block_pipe': {
          if (this.at(0) === BYTE_HASH) {
            this.index += 1;
            return this.finish('comment_block', start);
          }
          // Not a close: re-enter the body on the same byte.
          state = 'block_body';
          continue;
        }
      }
    }
  }

  /** Byte at `offset` from the cursor; `0` past the end (the sentinel). */
  private at(offset: number): number {
    const at = this.index + offset;
    return byteAt(this.bytes, at);
  }

  private finish(tag: TokenTag, start: number): Token {
    return { tag, start, end: this.index };
  }
}
