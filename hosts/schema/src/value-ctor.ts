// Value constructors — the typed `v.*` factory for SJON *atom values*.
//
// Disambiguated from the schema-node factory `s.*`: `s.symbol()` declares a
// *schema node* (a key whose value must be a symbol); `v.sym("x")` builds the
// *value* `{$sym:"x"}`. The output objects are exactly the plan-01 brands
// (`infer.ts`) and `serializeValue`'s `$`-tagged shape (`value.ts`), so a
// `v.*` result drops straight into a `Form.create` field, a `sjon\`\`` hole, or
// an `e.*` argument.
//
// Each constructor carries a cheap runtime guard that rejects content which is
// not a legal *bare token* for its kind — caught here, with a clear message,
// rather than surfacing later as a confusing parse/validate failure on the
// emitted text. The grammar mirrors `src/Lexer.zig` (symbol_body 510-518,
// keyword_body 496-508, reserved literals 590-594), NOT the looser
// manifest-atom regex in `serialize.ts`.

import type { CrossRef, Keyword, SjonDate, SjonTime, SjonUnit, Symbol_ } from './infer.ts';

// ---------------------------------------------------------------------------
// Bare-token grammar (mirrors src/Lexer.zig)
// ---------------------------------------------------------------------------

// symbol_body (`Lexer.zig:512`): letters, digits, and these specials (incl `#`).
const SYMBOL_BODY = charset(
  'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-*/<>=!?.%&|^~$@#',
);
// symbol head (`Lexer.zig:252` + the `.minus` path): symbol_body minus digits and `#`.
const SYMBOL_HEAD = charset(
  'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_+-*/<>=!?.%&|^~$@',
);
// keyword_body (`Lexer.zig:498`): symbol_body minus `#`; a leading digit is fine.
const KEYWORD_BODY = charset(
  'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-*/<>=!?.%&|^~$@',
);
// Bare symbols spelling these promote to their own token (`Lexer.zig:590`), so
// they can never round-trip as a symbol value.
const RESERVED_SYMBOLS: ReadonlySet<string> = new Set(['true', 'false', 'nil']);
// Whitespace + structural delimiters that terminate any bare token.
const STRUCTURAL = charset(' \t\n\r()[]{}";,');

function charset(chars: string): ReadonlySet<string> {
  return new Set(chars.split(''));
}

function isDigit(ch: string): boolean {
  return ch >= '0' && ch <= '9';
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/** A symbol value: `v.sym("red")` → `{$sym:"red"}` → `red`. */
export const sym = <const S extends string>(name: S): Symbol_<S> => {
  assertBareSymbol(name);
  return { $sym: name };
};

/** A keyword value: `v.kw("mode")` → `{$kw:"mode"}` → `:mode`. */
export const kw = <const S extends string>(name: S): Keyword<S> => {
  assertBareKeyword(name);
  return { $kw: name };
};

/** A date value: `v.date("2024-01-31")` → `{$date:…}` → `2024-01-31`. */
export const date = (iso: string): SjonDate => {
  assertNoStructural('date', iso);
  return { $date: iso };
};

/** A time value: `v.time("12:30:00")` → `{$time:…}` → `12:30:00`. */
export const time = (iso: string): SjonTime => {
  assertNoStructural('time', iso);
  return { $time: iso };
};

/** A unit-suffixed number: `v.unit(90, "deg")` → `{$num:[90,"deg"]}` → `90deg`. */
export const unit = <const U extends string>(value: number, unitToken: U): SjonUnit<U> => {
  assertUnit(unitToken);
  return { $num: [value, unitToken] };
};

/**
 * A cross-reference value — a symbol whose ref-ness is compile-time only
 * (`{$sym}` at runtime). Lines up with an `s.crossRef(target)` field: the
 * phantom `T` is the referenced form's head.
 */
export const ref = <const T extends string = string, const S extends string = string>(
  name: S,
): CrossRef<T, S> => {
  assertBareSymbol(name);
  return { $sym: name };
};

// ---------------------------------------------------------------------------
// Guards
// ---------------------------------------------------------------------------

function assertBareSymbol(name: string): void {
  if (name.length === 0) throw new Error('SJON v.sym: a symbol name cannot be empty.');
  if (RESERVED_SYMBOLS.has(name)) {
    throw new Error(
      `SJON v.sym: "${name}" is a reserved literal (true/false/nil) — it would lex as that literal, not a symbol. Use the literal directly.`,
    );
  }
  const head = name[0]!;
  if (head === '-' && name.length > 1 && isDigit(name[1]!)) {
    throw new Error(`SJON v.sym: "${name}" would lex as a negative number, not a symbol.`);
  }
  if (!SYMBOL_HEAD.has(head)) {
    throw new Error(
      `SJON v.sym: "${name}" must start with a letter or one of _ + - * / < > = ! ? . % & | ^ ~ $ @ (not a digit or #).`,
    );
  }
  for (const ch of name) {
    if (!SYMBOL_BODY.has(ch)) {
      throw new Error(
        `SJON v.sym: "${name}" contains an illegal symbol character (${JSON.stringify(ch)}).`,
      );
    }
  }
}

function assertBareKeyword(name: string): void {
  if (name.length === 0) throw new Error('SJON v.kw: a keyword name cannot be empty.');
  for (const ch of name) {
    if (!KEYWORD_BODY.has(ch)) {
      throw new Error(
        `SJON v.kw: ":${name}" contains an illegal keyword character (${JSON.stringify(ch)}).`,
      );
    }
  }
}

function assertNoStructural(kind: string, raw: string): void {
  if (raw.length === 0) throw new Error(`SJON v.${kind}: value cannot be empty.`);
  for (const ch of raw) {
    if (STRUCTURAL.has(ch)) {
      throw new Error(
        `SJON v.${kind}: ${JSON.stringify(raw)} contains whitespace or a delimiter — a bare ${kind} token cannot.`,
      );
    }
  }
}

function assertUnit(unitToken: string): void {
  assertNoStructural('unit', unitToken);
  const head = unitToken[0]!;
  // A unit fused onto a number must not look like more number: a leading
  // digit / sign / dot would re-lex as part of the numeral.
  if (isDigit(head) || head === '.' || head === '+' || head === '-') {
    throw new Error(
      `SJON v.unit: unit "${unitToken}" cannot start with a digit, sign, or dot — it would merge into the number.`,
    );
  }
}
