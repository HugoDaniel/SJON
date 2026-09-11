// The reserved `$`-prefixed discriminator keys of SJON's canonical JSON shape
// — the TypeScript source of truth shared across the two TS packages. Mirrors
// `src/SchemaExport/Discriminators.zig` and `src/Json.zig`'s canonical bridge;
// plugin-declared keys that begin with `$` are doubled at the wire (`$foo` →
// `$$foo`) per `Json.zig`. `@sjon-lang/typescript-parity` re-exports these (its
// `schemaExport/discriminators.ts` is a thin re-export) so a future addition to
// the JSON bridge surfaces as a missing constant, not as silent drift between
// the construction library and the validator port.

/** Form-head marker. Every form-shaped canonical JSON object carries `$form`. */
export const FORM_KEY = '$form';

/** Plugin-namespace marker. Omitted when the form's plugin is empty. */
export const NS_KEY = '$ns';

/** Positional children of a form (`$children`). */
export const CHILDREN_KEY = '$children';

/** Expression envelope (`$expr`). */
export const EXPR_KEY = '$expr';

/** Number-with-unit envelope (`$num`). */
export const NUM_KEY = '$num';

/** Keyword envelope (`$kw`). */
export const KW_KEY = '$kw';

/** Symbol envelope (`$sym`). */
export const SYM_KEY = '$sym';

/** Date envelope (`$date`). */
export const DATE_KEY = '$date';

/** Time envelope (`$time`). */
export const TIME_KEY = '$time';

/** Multi-root envelope (`$roots`). */
export const ROOTS_KEY = '$roots';

/** Full set, useful for collision checks (`$$`-escape detection). */
export const RESERVED_KEYS: readonly string[] = [
  FORM_KEY,
  NS_KEY,
  CHILDREN_KEY,
  EXPR_KEY,
  NUM_KEY,
  KW_KEY,
  SYM_KEY,
  DATE_KEY,
  TIME_KEY,
  ROOTS_KEY,
];
