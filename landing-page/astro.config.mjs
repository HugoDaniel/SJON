import { defineConfig } from 'astro/config';
import { unified } from '@astrojs/markdown-remark';
import starlight from '@astrojs/starlight';
import { sjonTextMateGrammar } from '@sjon/highlight';
import sjonLinkRewriter from './plugins/sjon-link-rewriter.mjs';
import { FIRST_LESSON, groupedLessons } from './src/lib/lessons.ts';

const base = '/pages/sjon';

// Who applies `base`, since it is three different answers on one page:
//   * sidebar `link:` — Starlight does it. Write these without the base.
//   * markdown links in a page body — `plugins/sjon-link-rewriter.mjs` does
//     it. Write these without the base too.
//   * frontmatter-literal links (`hero.actions[].link`, an explicit
//     `prev`/`next`) and component props (`<LinkCard href>`) — nobody does
//     it. These carry `/pages/sjon` themselves.
// Getting the second one wrong yields `/pages/sjon/pages/sjon/…`, which a
// `grep -rc 'pages/sjon/pages/sjon' dist/` after a build will find.
const tutorialSidebar = groupedLessons().map((part) => ({
  label: part.part,
  items: part.chapters.map((chapter) => ({
    label: chapter.chapter,
    items: chapter.lessons.map((lesson) => ({ label: lesson.title, link: lesson.route })),
  })),
}));

// https://astro.build/config
export default defineConfig({
  site: 'https://hugodaniel.com',
  base,
  redirects: {
    '/tutorial': `${base}${FIRST_LESSON.route}`,
  },
  integrations: [
    starlight({
      title: 'SJON',
      description:
        'A small embeddable data language where the schema is the contract, validated the same in Zig, JS, and Rust, with diagnostics precise enough for an agent to act on.',
      // `replacesTitle: true` because the mark already *is* the word: it is a
      // wordmark set in `<text font-family="Georgia, serif">`, so leaving the
      // title as real text next to it printed "sjon SJON" in the header. With
      // this on, Starlight keeps the title in a visually-hidden span, so the
      // name still reaches a screen reader and the tab title is unaffected.
      logo: {
        light: './src/assets/logo.svg',
        dark: './src/assets/logo-dark.svg',
        replacesTitle: true,
      },
      favicon: '/favicon.svg',
      // `theme.css` is the accent ramp and nothing else; `mastery-quiz.css`
      // paints markup that `src/lib/quiz-html.ts` emits as raw HTML, which is
      // why it cannot be a scoped component stylesheet; `home.css` is one rule
      // that pulls the splash page's prose back to a readable measure, global
      // only because a content-collection MDX file has nowhere to put a
      // `<style>` of its own.
      customCss: [
        './src/styles/theme.css',
        './src/styles/mastery-quiz.css',
        './src/styles/home.css',
      ],
      social: [
        { icon: 'seti:git', label: 'Source', href: 'https://git.hugodaniel.com/releases/sjon' },
      ],
      // Expressive Code owns every fenced block now, which is why
      // `markdown.shikiConfig` is gone: Starlight sets `markdown.syntaxHighlight`
      // to `false` and the Shiki config would be read by nothing.
      expressiveCode: {
        shiki: { langs: [sjonTextMateGrammar] },
      },
      // Ordered as the site reads rather than as a link list: learn, try,
      // compare, look up. Two labels are load-bearing. `/compare` matches its
      // own page title so a click never lands somewhere apparently different,
      // and `/errors` is "Diagnostic codes" rather than "Diagnostics" because
      // the tutorial already owns a part called "Schemas and Diagnostics" and
      // one sidebar cannot say the same word about two different things.
      sidebar: [
        ...tutorialSidebar,
        { label: 'Playground', link: '/playground' },
        { label: 'SJON next to JSON and EDN', link: '/compare' },
        { label: 'Diagnostic codes', link: '/errors' },
      ],
    }),
  ],
  markdown: {
    // Astro 7 defaults to the Sätteri processor; we stay on the
    // remark/rehype one because the lesson pipeline is remark-based.
    // Plugins live on the processor now — `markdown.remarkPlugins` is
    // deprecated. Starlight *mutates* this processor rather than replacing it
    // (`integrations/markdown-plugins.ts` pushes onto
    // `processor.options.remarkPlugins`), so the rewriter survives alongside
    // Starlight's own three.
    processor: unified({
      remarkPlugins: [[sjonLinkRewriter, { base }]],
    }),
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
