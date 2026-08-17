// Internal utilities — deliberately NOT part of the public `@sjon/schema`
// surface (`index.ts` never re-exports this module). Small, zero-dependency
// helpers the builder and serializer share.

/**
 * Compile-time exhaustiveness guard. In a `switch` over a discriminated
 * union, ending with `default: return assertNever(x)` makes adding an
 * unhandled variant a *type* error — the new variant is no longer assignable
 * to the `never` parameter, so the call fails to compile and points at the
 * switch that forgot it. The runtime `throw` is only a backstop for a value
 * forged past the type system (e.g. cast through `unknown`).
 */
export function assertNever(x: never): never {
  throw new Error(`SJON schema: unhandled variant ${JSON.stringify(x)}`);
}

/**
 * Narrow an `unknown` to a plain (non-null, non-array) object. The inferred
 * `x is Record<string, unknown>` predicate replaces the open-coded
 * `x !== null && typeof x === 'object' && !Array.isArray(x)` probe at every
 * call site — real narrowing instead of a bare boolean, so a following
 * `x['$form']` needs no cast.
 */
export function isRecord(x: unknown): x is Record<string, unknown> {
  return x !== null && typeof x === 'object' && !Array.isArray(x);
}

/** An {@link isRecord} that additionally carries a `$form` discriminator. */
export function isFormObject(x: unknown): x is Record<string, unknown> {
  return isRecord(x) && '$form' in x;
}

// --- member spellings ------------------------------------------------------

/** Largest member magnitude, mirroring `Plugin.NumericSpelling.MAX_SPELLING_VALUE`. */
const MAX_MEMBER_MAGNITUDE = 2 ** 53;

/** A unit tail: ASCII letters, hyphen-joined, or a single `%` (`Lexer.number_unit`). */
const MEMBER_UNIT_RE = /^(?:[A-Za-z]+(?:-[A-Za-z]+)*|%)$/;

/** A bare symbol spelling (`serialize.ts`'s `SYMBOL_RE`, kept in step by the tests). */
const MEMBER_SYMBOL_RE = /^[A-Za-z_][\w-]*$/;

/** True when `spelling` lexes as a unit-bearing number rather than a symbol. */
export function isDigitLeadingMember(spelling: string): boolean {
  const head = spelling[0];
  return head !== undefined && head >= '0' && head <= '9';
}

/**
 * Validate a `s.symbolMembers` spelling and return the text the manifest
 * should declare. Throws on a spelling the engine's loader would reject, so a
 * mistake surfaces where it was written rather than as an `invalid_manifest`
 * diagnostic on a serialized manifest nobody has read yet.
 *
 * Digit-leading spellings are **canonicalised**, exactly as
 * `ManifestLoader.parseMemberName` canonicalises them: `02d` declares the
 * member `2d`, so that is what gets written. Rejecting a legal spelling would
 * make this builder stricter than the language; silently writing `02d` would
 * make the manifest's member name disagree with every diagnostic about it.
 */
export function canonicalMemberName(spelling: string): string {
  if (spelling.length === 0) {
    throw new Error('SJON s.symbolMembers: a member spelling cannot be empty.');
  }
  if (!isDigitLeadingMember(spelling)) {
    if (!MEMBER_SYMBOL_RE.test(spelling)) {
      throw new Error(
        `SJON s.symbolMembers: "${spelling}" is neither a bare symbol nor a digit-leading spelling — ` +
          'a symbol member starts with a letter or `_` and continues with letters, digits, `_`, or `-`.',
      );
    }
    return spelling;
  }
  const split = /^([0-9][0-9_]*(?:\.[0-9_]+)?)(.*)$/.exec(spelling);
  const magnitudeText = split?.[1];
  const unit = split?.[2];
  if (magnitudeText === undefined || unit === undefined || unit.length === 0) {
    throw new Error(
      `SJON s.symbolMembers: member spelling "${spelling}" carries no unit; ` +
        'a digit-leading member needs a letter tail, e.g. `1d`.',
    );
  }
  if (!MEMBER_UNIT_RE.test(unit)) {
    throw new Error(
      `SJON s.symbolMembers: member spelling "${spelling}" has the unit "${unit}", which is not ` +
        'ASCII letters (optionally hyphen-joined) or a single `%` — it would not lex as one token.',
    );
  }
  const magnitude = Number(magnitudeText.replaceAll('_', ''));
  if (!Number.isInteger(magnitude) || magnitude > MAX_MEMBER_MAGNITUDE) {
    throw new Error(
      `SJON s.symbolMembers: member spelling "${spelling}" needs a whole magnitude at or below ` +
        `${MAX_MEMBER_MAGNITUDE} — matching is integer-keyed, so a fractional one could never match.`,
    );
  }
  return `${magnitude}${unit}`;
}
