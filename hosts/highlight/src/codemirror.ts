// @sjon/highlight — CodeMirror grammar for `.sjon`.
//
// A faithful `.sjon` (S-expression) tokenizer for a CodeMirror 6
// `StreamLanguage`, seeded from PNGine's `sjonToken`
// (pngine/web/editor/src/lib/codemirror-setup.js) and contributed back into
// SJON as the canonical, reusable grammar so every host can drop the Clojure
// approximation. Clojure mis-tokenizes the two constructs `.sjon` leans on:
//   - triple-quoted raw strings `"""…"""` (multi-line shader bodies), and
//   - leading-`;` line comments.
//
// The token classes returned are the camelCase `@lezer/highlight` tag names
// CM6's `StreamLanguage` maps through its default token table: `lineComment` /
// `blockComment` (→ `tags.comment`), `string`, `propertyName`, `punctuation`,
// `number`, `keyword`, `atom`, or `null` for the default foreground. Form heads
// (the symbol right after `(`) are styled as keywords; `:keys` as propertyName.

import { StreamLanguage, type StreamParser, type StringStream } from '@codemirror/language';

/**
 * Tokenizer state, carried across lines so multi-line spans resume correctly.
 * `StreamLanguage` shallow-copies this between lines (no custom `copyState`
 * needed — every field is a primitive).
 */
export interface SjonStreamState {
  /** Inside a `"""…"""` raw string body opened on an earlier line. */
  inRaw: boolean;
  /** Inside a `#| … |#` block comment opened on an earlier line. */
  inBlock: boolean;
  /** The previous token was `(`, so the next symbol is a form head. */
  afterParen: boolean;
}

// SJON literal atoms (the three reserved scalars).
const SJON_ATOMS = new Set(['true', 'false', 'nil']);

/**
 * Tokenize one `.sjon` token, advancing `stream` and mutating `state`. Returns
 * a `@lezer/highlight` tag name (camelCase) or `null` for default text.
 *
 * Exported for headless unit tests (driven directly over a `StringStream`); the
 * editor consumes it via `sjonStreamParser` / `sjonLanguage` below.
 */
export function sjonToken(stream: StringStream, state: SjonStreamState): string | null {
  // Raw-string body (carried across lines via state.inRaw).
  if (state.inRaw) {
    while (!stream.eol()) {
      if (stream.match('"""')) {
        state.inRaw = false;
        return 'string';
      }
      stream.next();
    }
    return 'string';
  }
  // Block-comment body `#| … |#` (carried across lines).
  if (state.inBlock) {
    while (!stream.eol()) {
      if (stream.match('|#')) {
        state.inBlock = false;
        return 'blockComment';
      }
      stream.next();
    }
    return 'blockComment';
  }

  if (stream.eatSpace()) return null;

  // Line comment.
  if (stream.match(';')) {
    stream.skipToEnd();
    state.afterParen = false;
    return 'lineComment';
  }
  // Block comment open.
  if (stream.match('#|')) {
    state.inBlock = true;
    state.afterParen = false;
    return 'blockComment';
  }

  // Raw string `"""…"""` — checked BEFORE normal strings (it starts with `"`).
  if (stream.match('"""')) {
    state.afterParen = false;
    while (!stream.eol()) {
      if (stream.match('"""')) return 'string'; // opened and closed on one line
      stream.next();
    }
    state.inRaw = true; // spans to following lines
    return 'string';
  }
  // Normal string (single line); tolerate an unterminated one to EOL.
  if (stream.match(/^"(?:[^"\\]|\\.)*"/)) {
    state.afterParen = false;
    return 'string';
  }
  if (stream.peek() === '"') {
    stream.skipToEnd();
    state.afterParen = false;
    return 'string';
  }

  // Keyword key `:foo`.
  if (stream.match(/^:[^\s()[\]";]+/)) {
    state.afterParen = false;
    return 'propertyName';
  }

  // Open paren primes the next symbol as a form head.
  if (stream.peek() === '(') {
    stream.next();
    state.afterParen = true;
    return 'punctuation';
  }
  // Other delimiters.
  if (stream.match(/^[)[\]]/)) {
    state.afterParen = false;
    return 'punctuation';
  }

  // Numbers: optional sign, then either a hex integer or a decimal with an
  // optional exponent and a rejected-but-tolerated unit. The hex branch goes
  // FIRST: the decimal branch would match `0x1F` as `0` plus the unit `x`
  // and leave `1F` to colour as a second number, which is what the lexer
  // itself used to do before hex literals existed.
  //
  // The unit's `(?:-[a-zA-Z]+)*` tail is the lexer's hyphen rule: a `-`
  // continues the unit only before another letter, so `2d-array` is one
  // number and `1em-2` stays `1em` then `-2`.
  if (
    stream.match(
      /^-?(?:0[xX][0-9a-fA-F][0-9a-fA-F_]*|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?(?:[a-zA-Z]+(?:-[a-zA-Z]+)*|%)?)/,
    )
  ) {
    state.afterParen = false;
    return 'number';
  }

  // Symbols: form head (after `(`) → keyword; literals → atom; else plain.
  if (stream.match(/^[^\s()[\]":;]+/)) {
    const w = stream.current();
    const wasHead = state.afterParen;
    state.afterParen = false;
    if (SJON_ATOMS.has(w)) return 'atom';
    if (wasHead) return 'keyword';
    return null;
  }

  stream.next();
  state.afterParen = false;
  return null;
}

/** The `StreamParser` object (`{ startState, token }`) for CM6. */
export const sjonStreamParser: StreamParser<SjonStreamState> = {
  startState(): SjonStreamState {
    return { inRaw: false, inBlock: false, afterParen: false };
  },
  token: sjonToken,
};

/** A CodeMirror `Language` for `.sjon`, ready to drop into an editor's extensions. */
export const sjonLanguage = StreamLanguage.define(sjonStreamParser);
