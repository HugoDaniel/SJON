// Discriminator constants for the canonical JSON shape — a thin re-export of
// the single source in `@sjon-lang/schema` (`hosts/schema/src/discriminators.ts`),
// which mirrors `src/SchemaExport/Discriminators.zig` and `src/Json.zig`.
//
// Re-exporting (rather than re-declaring) makes the two TS packages share one
// definition, so a future addition to the JSON bridge surfaces as a missing
// constant here at compile time rather than as silent drift between the
// construction library and this validator port. `plugin.ts` and `loader.ts`
// import these from this module unchanged.

export {
  CHILDREN_KEY,
  DATE_KEY,
  EXPR_KEY,
  FORM_KEY,
  KW_KEY,
  NS_KEY,
  NUM_KEY,
  RESERVED_KEYS,
  ROOTS_KEY,
  SYM_KEY,
  TIME_KEY,
} from '@sjon-lang/schema';
