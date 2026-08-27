// The `docs` collection's loader: four sources, one collection.
//
// A collection takes exactly one loader, and this site's pages come from four
// places — hand-written MDX, the fifteen tutorial sources in `docs/tutorial/`,
// the 130 generated diagnostic explanations, and an index page over those. So
// the composition happens here rather than in `content.config.ts`.
//
// The lessons in particular used to reach the site by a different route
// entirely: a hand-run migrator wrote fifteen `content.md` files into the repo
// and nothing in the build invoked it, so editing a lesson silently kept
// serving the previous prose. Reading `docs/tutorial/*.md` at build time is
// what retires that. The transforms are unchanged — see `lesson-transforms.ts`.
//
// ## The hazard this is shaped around
//
// `glob()`'s `load()` opens with `new Set(store.keys())` and closes by deleting
// every id it did not touch (`astro/dist/content/loaders/glob.js:63,231`). Run
// it beside programmatic entries and it wipes all 145 of them. The fix is the
// `scopedStore` below: hand the glob sub-loader a store whose `keys()` hides
// the ids it does not own. Ordering the calls the other way round would also
// work, but it would defeat `store.set`'s digest short-circuit and make every
// dev reload re-render everything.

import type { Loader, LoaderContext } from 'astro/loaders';
import { docsLoader } from '@astrojs/starlight/loaders';
import { readFile } from 'node:fs/promises';
import { LESSONS, type Lesson } from './lessons.ts';
import { ERRORS, type ErrorEntry } from './errors.ts';
import { transformLesson } from './lesson-transforms.ts';

/** The collection id a lesson is stored under, which is also its route. */
const lessonId = (lesson: Lesson): string => lesson.route.replace(/^\//, '');

/** The collection id a diagnostic code is stored under. */
const errorId = (entry: ErrorEntry): string => `errors/${entry.code}`;

/**
 * The repair lesson, for the footer every diagnostic page carries.
 *
 * Looked up rather than written out because the route is `lessons.ts`'s to
 * change: a literal here would survive a rename as 130 dead links, and the
 * throw turns that into a build failure instead.
 */
const REPAIR_LESSON: Lesson = (() => {
  const found = LESSONS.find((l) => l.slug === 'diagnostics-driven-repair');
  if (found === undefined) {
    throw new Error(
      "no lesson with slug 'diagnostics-driven-repair'; the error-page footer has no target.",
    );
  }
  return found;
})();

/**
 * The last line of every diagnostic page.
 *
 * Most of the 130 explanations are a single sentence, and the CLI's `help:`
 * link and the language server both send people straight to one of them.
 * Without this the arrival is a dozen words and no way onward that isn't the
 * browser's back button. Written as markdown links without the base, which is
 * `sjon-link-rewriter.mjs`'s job to add.
 */
const errorFooter = (code: string): string =>
  `\n\n---\n\nRun \`sjon explain ${code}\` to read this at a terminal, browse ` +
  `[every code](/errors), or work through ` +
  `[diagnostics-driven repair](${REPAIR_LESSON.route}) if you want the habit ` +
  `rather than the answer.\n`;

/**
 * A view of `store` whose `keys()` hides everything this loader generates.
 *
 * `scopedStore()` hands out a plain object literal of arrow functions
 * (`astro/dist/content/mutable-data-store.js:261`), so spreading it keeps every
 * method working and overriding one is enough.
 */
function hidingGenerated(store: LoaderContext['store'], generated: Set<string>) {
  return { ...store, keys: () => store.keys().filter((id) => !generated.has(id)) };
}

/**
 * Join `path` onto the site's `base`.
 *
 * Needed because Starlight applies `base` to sidebar links but *not* to links
 * written literally in frontmatter: `applyPrevNextLinkConfig` takes
 * `href: config.link` verbatim. Every `prev`/`next` this loader synthesises
 * therefore has to carry the base itself.
 */
function withBase(base: string, path: string): string {
  const prefix = base.replace(/\/+$/, '');
  return prefix === '' ? path : prefix + path;
}

/** A prev/next link, or `false` at either end of a sequence. */
type PrevNext = { link: string; label: string } | false;

function neighbour<T>(
  items: readonly T[],
  index: number,
  step: -1 | 1,
  toLink: (item: T) => { link: string; label: string },
): PrevNext {
  const item = items[index + step];
  return item === undefined ? false : toLink(item);
}

async function loadLessons(context: LoaderContext): Promise<void> {
  const sourceDir = new URL('../docs/tutorial/', context.config.root);
  const toLink = (lesson: Lesson) => ({
    link: withBase(context.config.base, lesson.route),
    label: lesson.title,
  });

  for (const [i, lesson] of LESSONS.entries()) {
    const sourcePath = new URL(`${lesson.sourceStem}.md`, sourceDir);
    // No frontmatter in the source: `docs/tutorial/*.md` is prose a human
    // reads in the repo. Everything Starlight needs comes from `lessons.ts`
    // through `parseData`, which is exactly why the migrator can die.
    const body = transformLesson(await readFile(sourcePath, 'utf8'), lesson);
    const id = lessonId(lesson);
    const digest = context.generateDigest(body);

    const data = await context.parseData({
      id,
      data: {
        title: lesson.title,
        description: lesson.gloss,
        prev: neighbour(LESSONS, i, -1, toLink),
        next: neighbour(LESSONS, i, 1, toLink),
        // The quiz is scored by a plain script, loaded per lesson rather than
        // site-wide. `defer` is load-bearing: it is an IIFE that queries
        // `.mastery-quiz` the moment it runs, and a `<head>` script without
        // `defer` runs before the body it is looking for exists.
        head: [
          {
            tag: 'script',
            attrs: { src: withBase(context.config.base, '/mastery-quiz.js'), defer: true },
          },
        ],
      },
    });

    context.store.set({ id, data, body, digest, rendered: await context.renderMarkdown(body) });
  }
}

async function loadErrors(context: LoaderContext): Promise<void> {
  const toLink = (entry: ErrorEntry) => ({
    link: withBase(context.config.base, `/errors/${entry.code}`),
    label: entry.code,
  });

  for (const [i, entry] of ERRORS.entries()) {
    // The explanation prose is already markdown — 31 of the 130 entries use
    // inline code, two contain fenced blocks and one a bullet list — and it
    // now goes through the real pipeline instead of a hand-rolled reflow that
    // ran fences together onto one line with the backticks showing.
    const prose = entry.long ? `${entry.short}\n\n${entry.long}` : `${entry.short}\n`;
    const body = prose + errorFooter(entry.code);
    const id = errorId(entry);
    const digest = context.generateDigest(body);

    const data = await context.parseData({
      id,
      data: {
        title: entry.code,
        description: entry.short,
        // 130 rows are deliberately not in the sidebar, and Starlight derives
        // pagination from the sidebar, so these have to be spelled out.
        // Catalogue order is the wire-stable enum's declaration order: related
        // codes were appended together, which lands a reader beside the ones
        // they are most likely to hit in the same session.
        prev: neighbour(ERRORS, i, -1, toLink),
        next: neighbour(ERRORS, i, 1, toLink),
      },
    });

    context.store.set({ id, data, body, digest, rendered: await context.renderMarkdown(body) });
  }
}

/** The composed loader. See the module header for why it is composed at all. */
export function sjonDocsLoader(): Loader {
  const files = docsLoader();

  return {
    name: 'sjon-docs-loader',
    async load(context: LoaderContext): Promise<void> {
      const generated = new Set<string>([...LESSONS.map(lessonId), ...ERRORS.map(errorId)]);

      await files.load({ ...context, store: hidingGenerated(context.store, generated) });
      await loadLessons(context);
      await loadErrors(context);
    },
  };
}
