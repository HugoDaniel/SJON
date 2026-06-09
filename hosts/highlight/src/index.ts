// @sjon/highlight — reusable `.sjon` syntax-highlighting grammars.
//
//   import { sjonLanguage } from '@sjon/highlight';        // CodeMirror 6
//   import { sjonTextMateGrammar } from '@sjon/highlight';  // Shiki / TextMate
//
//   // CodeMirror playground:
//   EditorState.create({ extensions: [sjonLanguage, …] });
//
//   // Shiki (static docs, markdown):
//   createHighlighter({ langs: [sjonTextMateGrammar], … });
//   hl.codeToHtml(code, { lang: 'sjon', … });
//
// Two engines, one source of truth — both seeded from PNGine's `sjonToken`, so
// every SJON host drops the Clojure approximation. The grammars are authored to
// agree on the constructs Clojure gets wrong (triple-quoted raw strings,
// leading-`;` comments) and on form-head / `:key` styling.
//
// Source-only package: consumers (Astro/Vite) transpile the `.ts` and resolve
// the `.json` directly — there is no build step.

export { sjonToken, sjonStreamParser, sjonLanguage } from './codemirror.ts';
export type { SjonStreamState } from './codemirror.ts';

import type { LanguageRegistration } from 'shiki';
import grammar from './sjon.tmLanguage.json';

/**
 * The TextMate grammar for `.sjon`, typed for Shiki. Pass it via
 * `langs: [sjonTextMateGrammar]`, then highlight with `lang: 'sjon'`.
 */
export const sjonTextMateGrammar = grammar as unknown as LanguageRegistration;
