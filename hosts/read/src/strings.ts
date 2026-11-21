// String-value decoding for the reader.
//
// Ported from `Parser.decodeString` and the `.raw_string` arm of `makeLeaf`:
// the decoded value is a byte-level transformation first, then one UTF-8
// decode. That order matters. `\é` is an unknown escape followed by a
// continuation byte, and the engine copies both bytes unchanged, so decoding
// each escape branch to a JS string separately would corrupt it into U+FFFD.
//
// Recognised escapes are exactly `n t r " \ 0` (the steady-state grammar, not
// the stale `\u{NNNN}` prose in docs/LANGUAGE.md — README correction 4).
// Anything else emits one err diagnostic spanning the whole string token and
// copies the escaped byte through. Raw strings never decode escapes at all.
//
// Diagnostics are path-agnostic here: the caller supplies the semantic path
// once the parser knows where the string sits (Task 4/5), and every diagnostic
// from one string carries it.

import type { ReadDiagnostic } from './diagnostics.ts';
import type { Token } from './lexer.ts';
import { decodeRange } from './source.ts';

export interface DecodedString {
  readonly value: string;
  readonly diagnostics: readonly ReadDiagnostic[];
}

const BYTE_BACKSLASH = 0x5c;

/** Replacement byte for a recognised escape, or `null` for an unknown one. */
function escapeByte(escaped: number): number | null {
  switch (escaped) {
    case 0x6e: // n
      return 0x0a;
    case 0x74: // t
      return 0x09;
    case 0x72: // r
      return 0x0d;
    case 0x22: // "
      return 0x22;
    case 0x5c: // \
      return 0x5c;
    case 0x30: // 0
      return 0x00;
    default:
      return null;
  }
}

function decodeEscaped(bytes: Uint8Array, token: Token, path: readonly string[]): DecodedString {
  const innerStart = token.start + 1;
  const innerEnd = token.end - 1;
  // The decoded form is never longer than the inner body: every escape
  // consumes two source bytes and emits one.
  const out = new Uint8Array(Math.max(innerEnd - innerStart, 0));
  const diagnostics: ReadDiagnostic[] = [];
  let written = 0;
  let index = innerStart;

  while (index < innerEnd) {
    const byte = bytes[index] ?? 0;
    if (byte === BYTE_BACKSLASH && index + 1 < innerEnd) {
      const escaped = bytes[index + 1] ?? 0;
      const replacement = escapeByte(escaped);
      if (replacement === null) {
        diagnostics.push({
          code: 'unspecified',
          severity: 'err',
          message: 'unrecognized string escape',
          span: { start: token.start, end: token.end },
          path,
        });
        out[written] = escaped;
      } else {
        out[written] = replacement;
      }
      written += 1;
      index += 2;
      continue;
    }
    out[written] = byte;
    written += 1;
    index += 1;
  }

  return { value: decodeRange(out, 0, written), diagnostics };
}

/**
 * Decode one string token to its runtime value plus any escape diagnostics.
 *
 * `token.tag` must be `string` or `raw_string` — a lexer-produced token of
 * either kind always has at least two delimiter bytes. `path` is attached to
 * every emitted diagnostic; the parser passes its frame path, tests may omit
 * it. Complexity O(token length).
 */
export function decodeStringValue(
  bytes: Uint8Array,
  token: Token,
  path: readonly string[] = [],
): DecodedString {
  switch (token.tag) {
    case 'string':
      return decodeEscaped(bytes, token, path);
    case 'raw_string':
      // `lexeme[3..len-3]`, verbatim: no escape processing, no newline
      // stripping, no dedent, no CRLF normalisation.
      return {
        value: decodeRange(bytes, token.start + 3, token.end - 3),
        diagnostics: [],
      };
    default:
      throw new TypeError(
        `decodeStringValue expects a string or raw_string token, got ${token.tag}`,
      );
  }
}
