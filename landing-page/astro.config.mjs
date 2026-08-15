import { defineConfig } from 'astro/config';
import { unified } from '@astrojs/markdown-remark';
import { sjonTextMateGrammar } from '@sjon/highlight';
import sjonLinkRewriter from './plugins/sjon-link-rewriter.mjs';
import { shikiThemes, shikiTransformers } from './src/lib/shiki-config.mjs';

const base = '/pages/sjon';

// https://astro.build/config
export default defineConfig({
  site: 'https://hugodaniel.com',
  base,
  redirects: {
    '/tutorial': `${base}/foundations/syntax/orientation`,
  },
  markdown: {
    // Astro 7 defaults to the Sätteri processor; we stay on the
    // remark/rehype one because the lesson pipeline is remark-based.
    // Plugins live on the processor now — `markdown.remarkPlugins` is
    // deprecated. `shikiConfig` stays put: it's processor-agnostic.
    processor: unified({
      remarkPlugins: [[sjonLinkRewriter, { base }]],
    }),
    shikiConfig: {
      langs: [sjonTextMateGrammar],
      themes: shikiThemes,
      transformers: shikiTransformers,
      defaultColor: false,
    },
  },
  vite: {
    resolve: {
      // CodeMirror keeps module-level singletons, so two copies of
      // `@codemirror/state` in one bundle do not merely waste bytes —
      // an extension minted by one is unrecognisable to the other, and
      // `EditorState.create` throws *"Unrecognized extension value in
      // extension set"* before the playground draws anything.
      //
      // Which is what happened: `@sjon/highlight` is consumed as
      // TypeScript source (`exports: './src/index.ts'`), so Vite
      // resolves its `@codemirror/language` import from
      // `hosts/highlight/node_modules` — where a `^6.10.6` range had
      // settled on 6.12.3, pulling in state 6.6.0 — while this package's
      // own `^6.12.4` resolved to 6.12.4 and state 6.7.1. The
      // `sjonLanguage` extension was built by 6.6.0 and handed to an
      // editor built by 6.7.1.
      //
      // Deduping is the fix CodeMirror itself prescribes, and it is the
      // durable one: aligning the two ranges would fix today's skew and
      // leave the next one free to come back silently.
      // Listed: every `@codemirror`/`@lezer` package this app depends on,
      // not only the three `@sjon/highlight` imports today. A package that
      // is not shared costs nothing here, and the entry has to exist
      // *before* the import that would duplicate it — the day the grammar
      // starts pulling `@codemirror/autocomplete` is not the day to
      // discover this list was scoped to yesterday's import graph.
      dedupe: [
        '@codemirror/autocomplete',
        '@codemirror/commands',
        '@codemirror/language',
        '@codemirror/lint',
        '@codemirror/state',
        '@codemirror/view',
        '@lezer/common',
        '@lezer/highlight',
      ],
    },
  },
});
