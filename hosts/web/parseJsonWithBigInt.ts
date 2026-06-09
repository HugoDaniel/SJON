// Minimal BigInt-aware JSON parser.
//
// `wasm_common.appendValue` emits integer-shaped `Expr.Value` variants
// (`integer_i64` / `integer_u64`) as plain JSON number tokens — the
// payload is bit-faithful, but standard `JSON.parse` collapses any
// integer above `Number.MAX_SAFE_INTEGER` onto its nearest f64
// neighbour. This parser preserves the exact value by returning
// `BigInt` for pure-integer tokens (no `.`, no exponent) when the
// magnitude is outside the JS Number safe range, and `Number` for
// everything else (fractional / exponent / safe-range integers).
//
// Shape supported: JSON5-free — the WASM output is RFC 8259 with the
// extras `wasm_common` emits (`"nan"` / `"inf"` / `"-inf"` for
// non-finite f64, encoded as strings, so they round-trip without
// blocking standard `JSON.parse`).
//
// Throws `SyntaxError` on malformed input — mirrors the JSON.parse
// contract so consumers can use the same `try/catch` shape.

const MAX_SAFE_BIGINT = BigInt(Number.MAX_SAFE_INTEGER);
const MIN_SAFE_BIGINT = BigInt(Number.MIN_SAFE_INTEGER);

interface Cursor {
  src: string;
  i: number;
}

/**
 * Parse a JSON string, returning BigInt for integer tokens whose
 * magnitude exceeds `Number.MAX_SAFE_INTEGER`. Every other shape
 * (fractionals, exponents, safe-range integers, strings, booleans,
 * null, arrays, objects) decodes to the same JS value `JSON.parse`
 * would produce.
 */
export function parseJsonWithBigInt(text: string): unknown {
  const c: Cursor = { src: text, i: 0 };
  skipWs(c);
  const v = readValue(c);
  skipWs(c);
  if (c.i !== c.src.length) throw new SyntaxError(`unexpected trailing input at position ${c.i}`);
  return v;
}

function skipWs(c: Cursor): void {
  while (c.i < c.src.length) {
    const ch = c.src[c.i];
    if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') c.i++;
    else break;
  }
}

function readValue(c: Cursor): unknown {
  skipWs(c);
  if (c.i >= c.src.length) throw new SyntaxError('unexpected end of input');
  const ch = c.src[c.i];
  if (ch === '{') return readObject(c);
  if (ch === '[') return readArray(c);
  if (ch === '"') return readString(c);
  if (ch === 't' || ch === 'f') return readBool(c);
  if (ch === 'n') return readNull(c);
  if (ch === '-' || (ch !== undefined && ch >= '0' && ch <= '9')) return readNumber(c);
  throw new SyntaxError(`unexpected character '${ch}' at position ${c.i}`);
}

function readObject(c: Cursor): Record<string, unknown> {
  c.i++; // '{'
  const out: Record<string, unknown> = {};
  skipWs(c);
  if (c.src[c.i] === '}') {
    c.i++;
    return out;
  }
  while (true) {
    skipWs(c);
    if (c.src[c.i] !== '"') throw new SyntaxError(`expected string key at position ${c.i}`);
    const key = readString(c);
    skipWs(c);
    if (c.src[c.i] !== ':') throw new SyntaxError(`expected ':' at position ${c.i}`);
    c.i++;
    out[key] = readValue(c);
    skipWs(c);
    if (c.src[c.i] === ',') {
      c.i++;
      continue;
    }
    if (c.src[c.i] === '}') {
      c.i++;
      return out;
    }
    throw new SyntaxError(`expected ',' or '}' at position ${c.i}`);
  }
}

function readArray(c: Cursor): unknown[] {
  c.i++; // '['
  const out: unknown[] = [];
  skipWs(c);
  if (c.src[c.i] === ']') {
    c.i++;
    return out;
  }
  while (true) {
    out.push(readValue(c));
    skipWs(c);
    if (c.src[c.i] === ',') {
      c.i++;
      continue;
    }
    if (c.src[c.i] === ']') {
      c.i++;
      return out;
    }
    throw new SyntaxError(`expected ',' or ']' at position ${c.i}`);
  }
}

function readString(c: Cursor): string {
  c.i++; // opening '"'
  const start = c.i;
  let needsUnescape = false;
  while (c.i < c.src.length) {
    const ch = c.src[c.i];
    if (ch === '"') {
      const raw = c.src.slice(start, c.i);
      c.i++;
      return needsUnescape ? (JSON.parse('"' + raw + '"') as string) : raw;
    }
    if (ch === '\\') {
      needsUnescape = true;
      c.i += 2;
      continue;
    }
    c.i++;
  }
  throw new SyntaxError('unterminated string');
}

function readBool(c: Cursor): boolean {
  if (c.src.startsWith('true', c.i)) {
    c.i += 4;
    return true;
  }
  if (c.src.startsWith('false', c.i)) {
    c.i += 5;
    return false;
  }
  throw new SyntaxError(`expected boolean at position ${c.i}`);
}

function readNull(c: Cursor): null {
  if (c.src.startsWith('null', c.i)) {
    c.i += 4;
    return null;
  }
  throw new SyntaxError(`expected 'null' at position ${c.i}`);
}

function readNumber(c: Cursor): number | bigint {
  const start = c.i;
  let isInt = true;
  if (c.src[c.i] === '-') c.i++;
  while (c.i < c.src.length) {
    const d = c.src[c.i];
    if (d === undefined || d < '0' || d > '9') break;
    c.i++;
  }
  if (c.src[c.i] === '.') {
    isInt = false;
    c.i++;
    while (c.i < c.src.length) {
      const d = c.src[c.i];
      if (d === undefined || d < '0' || d > '9') break;
      c.i++;
    }
  }
  if (c.src[c.i] === 'e' || c.src[c.i] === 'E') {
    isInt = false;
    c.i++;
    if (c.src[c.i] === '+' || c.src[c.i] === '-') c.i++;
    while (c.i < c.src.length) {
      const d = c.src[c.i];
      if (d === undefined || d < '0' || d > '9') break;
      c.i++;
    }
  }
  const lex = c.src.slice(start, c.i);
  if (isInt) {
    const big = BigInt(lex);
    if (big > MAX_SAFE_BIGINT || big < MIN_SAFE_BIGINT) return big;
    return Number(big);
  }
  return Number(lex);
}
