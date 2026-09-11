// @sjon-lang/highlight — reusable `.sjon` syntax-highlighting grammars.
//
//   import { sjonLanguage } from '@sjon-lang/highlight';        // CodeMirror 6
//   import { sjonTextMateGrammar } from '@sjon-lang/highlight';  // Shiki / TextMate
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
// Inside the workspace, consumers (Astro/Vite) transpile the `.ts` and resolve
// the `.json` directly. The published package is compiled to dist/ on
// `prepack` (`tsconfig.build.json`), because Node will not strip types under
// node_modules.

export { sjonToken, sjonStreamParser, sjonLanguage } from './codemirror.ts';
export type { SjonStreamState } from './codemirror.ts';

// The attribute is what lets Node's ESM loader import a `.json` at all, and
// the compiled dist/index.js keeps it verbatim.
import grammar from './sjon.tmLanguage.json' with { type: 'json' };

/**
 * The TextMate grammar for `.sjon`. Pass it to Shiki via
 * `langs: [sjonTextMateGrammar]`, then highlight with `lang: 'sjon'`.
 *
 * Typed by its own JSON shape rather than as Shiki's `LanguageRegistration`,
 * because `shiki` is not a dependency of this package: naming its type put
 * `import type … from 'shiki'` into the published `index.d.ts`, which fails
 * to resolve for every TypeScript consumer that only wants the CodeMirror
 * half. Shiki accepts the shape structurally, and `test/highlight.test.ts`
 * holds it to that by passing this export to a real `createHighlighter`.
 */
export const sjonTextMateGrammar = grammar;
