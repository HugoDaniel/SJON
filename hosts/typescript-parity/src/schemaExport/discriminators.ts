// Discriminator constants shared with `src/Json.zig`'s canonical JSON
// bridge — TypeScript port of `src/SchemaExport/Discriminators.zig`.
//
// These are the reserved `$`-prefixed keys the canonical JSON shape
// uses. Plugin-declared keys beginning with `$` are doubled at the
// wire (`$foo` → `$$foo`) per `Json.zig:135-148`. Centralised here so
// a future addition to the JSON bridge surfaces as a missing constant
// elsewhere in the exporter, not as silent drift.

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
