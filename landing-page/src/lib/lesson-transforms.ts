// The four edits that turn a `docs/tutorial/NN-*.md` source into the body a
// lesson page renders.
//
// These used to live inside `scripts/migrate-tutorials.mjs`, a hand-run
// generator that wrote fifteen `content.md` files into the repo. Nothing
// invoked it, so editing a lesson silently kept serving the previous prose.
// They are plain `string -> string` functions here so the content-layer
// loader can call them at build time, which removes the generated tree and
// the "did you remember to re-run the migrator?" step with it.
//
// Deliberately *not* remark plugins. A remark plugin is global: "strip the H1
// and the Goal section" would run over the homepage and all 130 error bodies
// too, and guarding each one with a per-file check is more machinery than the
// regexes it would replace. The loader already knows which fifteen files it
// is holding. Link rewriting stays a remark plugin, because it is the one
// transform that genuinely wants an mdast.

import { renderQuizHtml } from './quiz-html.ts';

/**
 * Drop the leading `# 01 - Foo` heading and the whole `## Goal` section, then
 * trim to a single trailing newline.
 *
 * The title is *not* derived here. Source H1s and displayed titles disagree —
 * `02-first-document.md` is titled "First Document" and renders as "Your first
 * document" — and `src/lib/lessons.ts` is what settles that.
 *
 * The `Goal` section runs from its heading to the next H2 or to end of file;
 * the lesson page states the goal through the sidebar gloss instead.
 */
export function stripLessonFrame(src: string): string {
  let body = src.replace(/^#\s+\d+\s*[-–—]\s*.+\r?\n/m, '');
  body = body.replace(/^##\s+Goal\b[^\n]*\n[\s\S]*?(?=^##\s|\Z)/m, '');
  body = body.replace(/\r?\n+Next:\s*\[[^\]]+\]\([^)]+\)\.?\s*$/m, '');
  return `${body.replace(/^\s+/, '').replace(/\s+$/, '')}\n`;
}

/**
 * Append an "Open in playground →" link under every fenced `sjon` block.
 *
 * The playground reads a base64url-encoded snippet off `location.hash` and
 * seeds the editor with it. Callers gate this on the early lessons: later ones
 * lean on schemas the playground has not loaded, so the editor would open
 * full of diagnostics that are about the setup rather than the snippet.
 *
 * The optional tail after the language is load-bearing. Expressive Code takes
 * its options off the fence's info string — `title=`, `frame=`, `ins=`,
 * `del=` — and a fence carrying any of them stops matching a
 * `` ```sjon\n `` pattern. That failure is silent: the block still renders, it
 * just loses its deep link, so nothing goes red and the lesson quietly ships
 * without it. The tail must start with whitespace, so a language that merely
 * begins with those four letters is still a different language.
 */
export function injectPlaygroundLinks(body: string): string {
  return body.replace(/```sjon(?:[ \t][^\n]*)?\n([\s\S]*?)\n```/g, (match, snippet: string) => {
    const encoded = Buffer.from(snippet.trim(), 'utf8').toString('base64url');
    return `${match}\n\n[Open in playground →](/playground#s=${encoded})`;
  });
}

/**
 * Swap the trailing `## Mastery Check` checklist for the scored quiz.
 *
 * The source bullets are open-ended prompts and are discarded; the questions
 * come from `src/data/mastery-quizzes.ts`, keyed by lesson slug.
 *
 * Note what the `slice(0, m.index)` does beyond making room for the quiz: it
 * truncates *everything* from the heading onward, which is what removes each
 * lesson's trailing `Next:` line — and, in lesson 15, a `Back to the [course
 * map](README.md)` that has no page on this site. The `Next:` regex in
 * `stripLessonFrame` gets the credit but rarely does the work. Keep the slice.
 */
export function replaceMasteryCheck(body: string, lessonSlug: string): string {
  const m = /\n##\s+Mastery Check[ \t]*\n+([\s\S]+)$/.exec(body);
  if (!m) return body;

  const html = renderQuizHtml(lessonSlug);
  // No questions for this lesson: drop the section rather than emit a heading
  // with an empty scoreboard under it.
  if (html === null) return body.slice(0, m.index);

  return body.slice(0, m.index) + html;
}

/**
 * Wrap the diagnostics lesson's codes table in a sticky container.
 *
 * One lesson wants it: the reader works through repair examples below the
 * table and needs the codes to stay in view. The table is located by its
 * header row rather than by position, so it survives prose being added above
 * it, and returns the body untouched if the table is not found.
 *
 * The blank lines around the wrapper are load-bearing — without them the
 * markdown processor stops recognising the GFM table inside a raw HTML block.
 */
export function wrapCodesTable(body: string): string {
  const tableStart = body.indexOf('| Code |');
  if (tableStart === -1) return body;
  const after = body.indexOf('\n\n', tableStart);
  if (after === -1) return body;
  const before = body.lastIndexOf('\n', tableStart - 1);
  const head = body.slice(0, before + 1);
  const table = body.slice(before + 1, after);
  const tail = body.slice(after);
  return [head, '<div class="codes-sticky">\n\n', table, '\n\n</div>', tail].join('');
}

/** Which lessons carry the sticky codes table. */
const STICKY_CODES_TABLE = 'diagnostics-driven-repair';

/** The last lesson that gets playground deep links. See `injectPlaygroundLinks`. */
const LAST_PLAYGROUND_LESSON = 8;

/**
 * Every transform, in the order they compose, for one lesson.
 *
 * Order matters twice: `replaceMasteryCheck` must run on a body that still
 * has its `## Mastery Check` heading, and `injectPlaygroundLinks` must run
 * after it so the quiz's own markup is never scanned for fences.
 */
export function transformLesson(src: string, lesson: { num: number; slug: string }): string {
  let body = stripLessonFrame(src);
  body = replaceMasteryCheck(body, lesson.slug);
  if (lesson.num <= LAST_PLAYGROUND_LESSON) body = injectPlaygroundLinks(body);
  if (lesson.slug === STICKY_CODES_TABLE) body = wrapCodesTable(body);
  return body;
}
