// `exactOptionalPropertyTypes`-only checks for the exclusive-group
// emission (Task 5, strict leg). This file is checked by the package
// `tsc --noEmit` (the option is ON there) and is deliberately EXCLUDED
// from `tsconfig.exact-off.json`: with the option off, every `?: never`
// slot widens to admit `undefined` and the rejection below disappears —
// an `@ts-expect-error` would then itself be the error.
//
// It is NOT a `.test.ts`, so the node:test glob never runs it.

import type { Xkey_Tag } from '../golden/xkey.d.ts';

// The none-arm spells every grouped key as `?: never`. With
// `exactOptionalPropertyTypes` on, a never slot admits no value — not
// even an explicit `undefined` — so writing `prefix: undefined` cannot
// sneak past the at-most-one group as a "present but absent" key: the
// none-arm rejects it (undefined is not assignable to never) and both
// arms reject it (undefined is not a string).
const explicitUndefinedDoc = {
  $form: 'tag',
  $ns: 'xkey',
  name: { $sym: 'badge' },
  prefix: undefined,
} as const;
// @ts-expect-error explicit undefined in a never slot (exactOptionalPropertyTypes)
const explicitUndefined: Xkey_Tag = explicitUndefinedDoc;

void explicitUndefined;
