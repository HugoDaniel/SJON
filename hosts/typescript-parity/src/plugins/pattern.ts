// The built-in `pattern` plugin — Strudel-style combinators as data forms,
// in the typescript-parity `Plugin` shape. Native mirror of
// `src/plugins/pattern.zig`.
//
// These FormSpecs exist for the validator (head recognition + accepting
// positional children); the pattern semantics are executed by the
// PatternQuery walker, not by any ExprFunc. `positional: { kind: 'any' }`
// because PositionalSpec can't express per-form arity — the compile step in
// `patternQuery.ts` enforces it. Seeded only on the pattern-query path, never
// in the default document schema.

import type { Plugin } from '../plugin.ts';

export const patternPlugin: Plugin = {
  name: 'pattern',
  version: '',
  authors: [],
  license: '',
  homepage: '',
  repository: '',
  keywords: [],
  sjonFormat: '',
  exprFuncs: [],
  valueKinds: [],
  crossRefProviders: [],
  forms: [
    { name: 'silence', keys: [], positional: { kind: 'none' }, open: false },
    { name: 'pure', keys: [], positional: { kind: 'any' }, open: false },
    { name: 'stack', keys: [], positional: { kind: 'any' }, open: false },
    { name: 'fast', keys: [], positional: { kind: 'any' }, open: false },
    { name: 'slow', keys: [], positional: { kind: 'any' }, open: false },
    { name: 'euclid', keys: [], positional: { kind: 'any' }, open: false },
    { name: 'slowcat', keys: [], positional: { kind: 'any' }, open: false },
    { name: 'cat', keys: [], positional: { kind: 'any' }, open: false },
  ],
};
