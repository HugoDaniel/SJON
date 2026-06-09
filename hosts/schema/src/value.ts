// Value serializer — a JS value in SJON's canonical "$-tagged" JSON shape
// → canonical SJON text. The pure-TS inverse of the `$`-tag codec
// (`src/Json.zig`) plus the canonical printer (`src/Printer.zig`); zero
// runtime deps, no WASM.
//
// This is the keystone of the write side: because it needs no engine, the
// whole construct → serialize → validate flow runs on *every* backend,
// including the native TS host that has no WASM printer. On a WASM backend
// `fromValue` (`sjon_from_json`) is the round-trip *oracle*, not a
// dependency: `toJson(serializeValue(v))` deep-equals `toJson(fromValue(v))`.
// Note the claim is **parse-equality**, not byte-identity — but the emit
// rules below deliberately match the printer so the oracle stays trivially
// green.
//
// Emit rules mirror, point for point, the Zig core (the parity-critical ones
// are flagged):
//   * strings escape ONLY `" \ \n \r \t \0` and pass every other byte raw,
//     including non-ASCII (`Printer.zig:writeString`, 630-648). ⚠ This is the
//     #1 parity trap: `JSON.stringify` would additionally escape `\b`/`\f`/
//     `\uXXXX`, which the SJON lexer does not accept the same way. Do NOT
//     reuse `serialize.ts:quote`.
//   * numbers: `nan` / `inf` / `-inf` for the non-finite f64s; integers
//     elide a trailing `.0` (`Printer.zig:formatNumberInto`, 575-584).
//     `String(x)` already does both.
//   * a form emits `(<$ns>/<$form> :key v … child …)` — namespace FIRST
//     (`Printer.zig:pushForm`, 313-318; round-trips as `(masagin/verb :ops
//     1)`). kvpair keys are bare `:key` (`pushKvPair`, 353-367); a user key
//     spelled `$$foo` in the JSON shape unescapes to `:$foo`
//     (`Json.zig:unescapeKey`, 144-147).
//   * an expr is `(op …args)` with the op BARE at index 0
//     (`Json.zig:exprFormToJson`, 408-424), never a `{$sym}`; a qualified
//     expr carries a sibling `$ns` → `(ns/op …)`.
//
// Lifetime: pure functions over JS-owned immutable data. No allocator handle.

/**
 * A value in SJON's canonical JSON shape — the same shape `toJson` produces
 * and `fromValue` consumes, and the supertype every plan-01 brand
 * (`Symbol_`, `Keyword`, `SjonExpr`, `SjonUnit`, a `FormOut`, …) is
 * assignable to. Construction precision (per-op expr typing, form-field
 * checking) lives in `e.*` / `FormIn`, not here — this type is deliberately
 * permissive so any well-formed value flows into `serializeValue`.
 */
export type SjonValue =
  | number
  | string
  | boolean
  | null
  | bigint
  | readonly SjonValue[]
  | { readonly $sym: string }
  | { readonly $kw: string }
  | { readonly $date: string }
  | { readonly $time: string }
  | { readonly $num: readonly [number, string] }
  | { readonly $expr: readonly unknown[] }
  | SjonFormValue;

/** The form variant of {@link SjonValue}: a head tag plus arbitrary keys. */
export interface SjonFormValue {
  readonly $form: string;
  readonly $ns?: string;
  readonly $children?: readonly SjonValue[];
  readonly [key: string]: unknown;
}

/** Structural keys that drive a form's shape rather than emit as kvpairs. */
const FORM_DISCRIMINATORS: ReadonlySet<string> = new Set(['$form', '$ns', '$children']);

/**
 * Serialize a {@link SjonValue} to canonical SJON text.
 *
 * Complexity: O(n) over the value tree (one recursive walk). Pure — the
 * input is read-only and never mutated. Throws `Error` on a structurally
 * impossible value (a plain object with no SJON discriminator, an `undefined`
 * leaf, a malformed `$expr`/`$num`) — these are programmer errors, not user
 * input, so a throw (not a diagnostic) is correct.
 */
export function serializeValue(value: SjonValue): string {
  return emit(value);
}

/**
 * Quote a string the way the SJON printer does: escape only `" \ \n \r \t
 * \0`, pass every other byte (including non-ASCII) through raw. Exported so
 * `serialize.ts` and tests can share the exact rule.
 */
export function quoteSjonString(text: string): string {
  let out = '"';
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]!;
    switch (ch) {
      case '"':
        out += '\\"';
        break;
      case '\\':
        out += '\\\\';
        break;
      case '\n':
        out += '\\n';
        break;
      case '\r':
        out += '\\r';
        break;
      case '\t':
        out += '\\t';
        break;
      case '\0':
        out += '\\0';
        break;
      default:
        out += ch;
    }
  }
  return out + '"';
}

// ---------------------------------------------------------------------------
// Recursive walk
// ---------------------------------------------------------------------------

function emit(value: unknown): string {
  if (value === null) return 'nil';
  switch (typeof value) {
    case 'boolean':
      return value ? 'true' : 'false';
    case 'number':
      return formatNumber(value);
    case 'bigint':
      return value.toString();
    case 'string':
      return quoteSjonString(value);
    case 'object':
      break;
    case 'undefined':
      throw new Error('SJON serializeValue: `undefined` is not a representable value.');
    default:
      throw new Error(`SJON serializeValue: cannot serialize a ${typeof value}.`);
  }
  if (Array.isArray(value)) return emitVector(value);

  // Dispatch on discriminators in the same order as `Json.objectToForm`
  // (`Discriminators.atom_keys`: $expr $num $kw $sym $date $time), then $form.
  const obj = value as Record<string, unknown>;
  if ('$expr' in obj) return emitExpr(obj);
  if ('$num' in obj) return emitUnit(obj);
  if ('$kw' in obj) return `:${unescapeKey(stringField(obj, '$kw'))}`;
  if ('$sym' in obj) return unescapeKey(stringField(obj, '$sym'));
  if ('$date' in obj) return stringField(obj, '$date');
  if ('$time' in obj) return stringField(obj, '$time');
  if ('$form' in obj) return emitForm(obj);
  throw new Error(
    'SJON serializeValue: object has no SJON discriminator ' +
      '($form / $expr / $sym / $kw / $date / $time / $num). ' +
      'Plain JS objects are not SJON values — build them with v.*, e.*, or Form.create.',
  );
}

function emitVector(items: readonly unknown[]): string {
  return `[${items.map(emit).join(' ')}]`;
}

function emitExpr(obj: Record<string, unknown>): string {
  const parts = obj['$expr'];
  if (!Array.isArray(parts) || parts.length === 0) {
    throw new Error('SJON serializeValue: $expr must be a non-empty array [op, …args].');
  }
  const op = unescapeKey(String(parts[0]));
  const ns = nsPrefix(obj);
  if (parts.length === 1) return `(${ns}${op})`;
  const args = parts.slice(1).map(emit).join(' ');
  return `(${ns}${op} ${args})`;
}

function emitUnit(obj: Record<string, unknown>): string {
  const num = obj['$num'];
  if (
    !Array.isArray(num) ||
    num.length !== 2 ||
    typeof num[0] !== 'number' ||
    typeof num[1] !== 'string'
  ) {
    throw new Error('SJON serializeValue: $num must be [number, unitString].');
  }
  return `${formatNumber(num[0])}${num[1]}`;
}

function emitForm(obj: Record<string, unknown>): string {
  const head = unescapeKey(stringField(obj, '$form'));
  const parts: string[] = [`${nsPrefix(obj)}${head}`];
  for (const key of Object.keys(obj)) {
    if (FORM_DISCRIMINATORS.has(key)) continue;
    const v = obj[key];
    if (v === undefined) continue; // omit absent optionals (EOPT-safe)
    parts.push(`:${unescapeKey(key)}`);
    parts.push(emit(v));
  }
  const children = obj['$children'];
  if (children !== undefined) {
    if (!Array.isArray(children)) {
      throw new Error('SJON serializeValue: $children must be an array of values.');
    }
    for (const ch of children) parts.push(emit(ch));
  }
  return `(${parts.join(' ')})`;
}

// ---------------------------------------------------------------------------
// Atom helpers
// ---------------------------------------------------------------------------

/** `(<ns>/` when the object carries a string `$ns`, else `""`. */
function nsPrefix(obj: Record<string, unknown>): string {
  const ns = obj['$ns'];
  return typeof ns === 'string' ? `${ns}/` : '';
}

/** Mirror `Json.zig:formatNumberInto` — non-finite tokens + integer elision. */
function formatNumber(x: number): string {
  if (Number.isNaN(x)) return 'nan';
  if (x === Infinity) return 'inf';
  if (x === -Infinity) return '-inf';
  return String(x);
}

/**
 * Invert `Json.zig:escapeKey`: a wire key spelled `$$foo` is the user key
 * `$foo`. Bridge discriminators (`$form`, `$sym`, …) never reach here with a
 * double prefix, so a single `$`-prefixed key passes through untouched.
 */
function unescapeKey(key: string): string {
  return key.startsWith('$$') ? key.slice(1) : key;
}

function stringField(obj: Record<string, unknown>, key: string): string {
  const v = obj[key];
  if (typeof v !== 'string') {
    throw new Error(`SJON serializeValue: ${key} must be a string.`);
  }
  return v;
}
