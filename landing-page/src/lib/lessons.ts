// Single source of truth for the tutorial sequence.
//
// Drives:
//   * src/components/LessonOutline.astro — landing-page TOC
//   * src/layouts/Lesson.astro             — sidebar nav inside lessons
//   * src/pages/[...slug].astro            — getStaticPaths()
//   * scripts/migrate-tutorials.mjs        — re-import (kept duplicate to
//                                             keep the migrator runnable
//                                             without TS tooling)
//   * plugins/sjon-link-rewriter.mjs       — sibling-link rewriting
//
// When you add or rename a lesson, update both this file *and* the
// LESSONS array in scripts/migrate-tutorials.mjs.

export interface Lesson {
  num: number;
  /** Source filename in docs/tutorial without the `.md`. */
  sourceStem: string;
  /** URL-visible slug. */
  slug: string;
  /** Title shown in the sidebar / outline. */
  title: string;
  /** One-line description for the landing-page outline. */
  gloss: string;
  /** Full URL path under which the lesson is rendered. */
  route: string;
  /** Disk path under src/content/tutorial (relative). */
  dir: string;
  /** Coarse grouping: part name shown in the sidebar. */
  part: string;
  /** Finer grouping: chapter name shown in the sidebar. */
  chapter: string;
}

export const LESSONS: readonly Lesson[] = [
  {
    num: 1,
    sourceStem: '01-orientation',
    slug: 'orientation',
    title: 'Orientation',
    gloss: 'What SJON is, what it isn’t, how it differs from JSON.',
    route: '/foundations/syntax/orientation',
    dir: '1-foundations/1-syntax/1-orientation',
    part: 'Foundations',
    chapter: 'Syntax and Atoms',
  },
  {
    num: 2,
    sourceStem: '02-first-document',
    slug: 'first-document',
    title: 'Your first document',
    gloss: 'Forms, keywords, vectors, and the canonical printer.',
    route: '/foundations/syntax/first-document',
    dir: '1-foundations/1-syntax/2-first-document',
    part: 'Foundations',
    chapter: 'Syntax and Atoms',
  },
  {
    num: 3,
    sourceStem: '03-atoms-and-intent',
    slug: 'atoms-and-intent',
    title: 'Atoms and intent',
    gloss: 'Symbols, strings, numbers, booleans, nil. When to reach for which.',
    route: '/foundations/syntax/atoms-and-intent',
    dir: '1-foundations/1-syntax/3-atoms-and-intent',
    part: 'Foundations',
    chapter: 'Syntax and Atoms',
  },
  {
    num: 4,
    sourceStem: '04-numbers-units-vectors',
    slug: 'numbers-units-vectors',
    title: 'Numbers, units, vectors',
    gloss: 'Unit suffixes, vector literals, when units are mandatory.',
    route: '/foundations/syntax/numbers-units-vectors',
    dir: '1-foundations/1-syntax/4-numbers-units-vectors',
    part: 'Foundations',
    chapter: 'Syntax and Atoms',
  },
  {
    num: 5,
    sourceStem: '05-forms-and-keyword-pairing',
    slug: 'forms-and-keyword-pairing',
    title: 'Forms and keyword pairing',
    gloss: 'How keys parse, how positionals work, how to read a (form …).',
    route: '/foundations/syntax/forms-and-keyword-pairing',
    dir: '1-foundations/1-syntax/5-forms-and-keyword-pairing',
    part: 'Foundations',
    chapter: 'Syntax and Atoms',
  },
  {
    num: 6,
    sourceStem: '06-comments-and-strings',
    slug: 'comments-and-strings',
    title: 'Comments and strings',
    gloss: 'Lossless comments, escape rules, raw strings.',
    route: '/foundations/syntax/comments-and-strings',
    dir: '1-foundations/1-syntax/6-comments-and-strings',
    part: 'Foundations',
    chapter: 'Syntax and Atoms',
  },
  {
    num: 7,
    sourceStem: '07-safe-expressions',
    slug: 'safe-expressions',
    title: 'Safe expressions',
    gloss: 'Parens that compute. The closed expression vocabulary.',
    route: '/foundations/expressions/safe-expressions',
    dir: '1-foundations/2-expressions/1-safe-expressions',
    part: 'Foundations',
    chapter: 'Expressions and Bindings',
  },
  {
    num: 8,
    sourceStem: '08-bindings-and-control-flow',
    slug: 'bindings-and-control-flow',
    title: 'Bindings and control flow',
    gloss: '(let …), (if …), (cond …). Bounded, deterministic, no recursion.',
    route: '/foundations/expressions/bindings-and-control-flow',
    dir: '1-foundations/2-expressions/2-bindings-and-control-flow',
    part: 'Foundations',
    chapter: 'Expressions and Bindings',
  },
  {
    num: 9,
    sourceStem: '09-reading-plugin-schemas',
    slug: 'reading-plugin-schemas',
    title: 'Reading plugin schemas',
    gloss:
      'Forms, keys, required/optional, defaults, positional policy, open forms, schema export.',
    route: '/schemas/reading/reading-plugin-schemas',
    dir: '2-schemas/1-reading/1-plugin-schemas',
    part: 'Schemas and Diagnostics',
    chapter: 'Reading Schemas',
  },
  {
    num: 10,
    sourceStem: '10-discriminated-and-exclusive-forms',
    slug: 'discriminated-and-exclusive-forms',
    title: 'Discriminated and exclusive forms',
    gloss: 'One head with variant shapes; exclusive groups; multi-key bundles.',
    route: '/schemas/reading/discriminated-and-exclusive-forms',
    dir: '2-schemas/1-reading/2-discriminated-and-exclusive',
    part: 'Schemas and Diagnostics',
    chapter: 'Reading Schemas',
  },
  {
    num: 11,
    sourceStem: '11-value-kinds-shapes',
    slug: 'value-kinds-shapes',
    title: 'Value kinds: shapes, vectors, units, bounds, representation',
    gloss:
      'Underlying shapes, vector shapes (fixed and variable length), unit shapes, numeric bounds, and representation tags.',
    route: '/schemas/reading/value-kinds-shapes',
    dir: '2-schemas/1-reading/3-value-kinds-shapes',
    part: 'Schemas and Diagnostics',
    chapter: 'Reading Schemas',
  },
  {
    num: 12,
    sourceStem: '12-value-kinds-refinements',
    slug: 'value-kinds-refinements',
    title: 'Value kinds: strings, members, heads, unions, slot-local forms',
    gloss:
      'String bounds, member sets, head sets, unions, slot-local forms, and the diagnostic cheat sheet.',
    route: '/schemas/reading/value-kinds-refinements',
    dir: '2-schemas/1-reading/4-value-kinds-refinements',
    part: 'Schemas and Diagnostics',
    chapter: 'Reading Schemas',
  },
  {
    num: 13,
    sourceStem: '13-cross-references',
    slug: 'cross-references',
    title: 'Cross-references',
    gloss: 'Document-spanning name lookups; acyclic constraints.',
    route: '/schemas/reading/cross-references',
    dir: '2-schemas/1-reading/5-cross-references',
    part: 'Schemas and Diagnostics',
    chapter: 'Reading Schemas',
  },
  {
    num: 14,
    sourceStem: '14-diagnostics-driven-repair',
    slug: 'diagnostics-driven-repair',
    title: 'Diagnostics-driven repair',
    gloss: 'The stable diagnostic codes as a repair workflow. Read, repair, repeat.',
    route: '/schemas/repair/diagnostics-driven-repair',
    dir: '2-schemas/2-repair/1-diagnostics-driven-repair',
    part: 'Schemas and Diagnostics',
    chapter: 'Repair and Style',
  },
  {
    num: 15,
    sourceStem: '15-style-portability-and-capstone',
    slug: 'style-portability-capstone',
    title: 'Style, portability, capstone',
    gloss: 'Canonical formatting, manifest portability, a capstone exercise.',
    route: '/schemas/repair/style-portability-capstone',
    dir: '2-schemas/2-repair/2-style-portability-capstone',
    part: 'Schemas and Diagnostics',
    chapter: 'Repair and Style',
  },
] as const;

/** First lesson — the target of `/tutorial`'s redirect and every "Take the
 * tutorial" link, so internal nav lands on a real page instead of bouncing
 * through the redirect's meta-refresh shim. */
const firstLesson = LESSONS[0];
if (firstLesson === undefined) {
  throw new Error('LESSONS must not be empty — FIRST_LESSON has no target.');
}
export const FIRST_LESSON: Lesson = firstLesson;

/** Lookup by route slug (path under /). */
export function lessonByRoute(route: string): Lesson | undefined {
  return LESSONS.find((l) => l.route === route);
}

/** Group lessons by part → chapter, preserving order. */
export interface ChapterGroup {
  chapter: string;
  lessons: readonly Lesson[];
}
export interface PartGroup {
  part: string;
  chapters: ChapterGroup[];
}

export function groupedLessons(): PartGroup[] {
  const parts: PartGroup[] = [];
  for (const lesson of LESSONS) {
    let p = parts.find((x) => x.part === lesson.part);
    if (!p) {
      p = { part: lesson.part, chapters: [] };
      parts.push(p);
    }
    let c = p.chapters.find((x) => x.chapter === lesson.chapter);
    if (!c) {
      c = { chapter: lesson.chapter, lessons: [] };
      p.chapters.push(c);
    }
    (c.lessons as Lesson[]).push(lesson);
  }
  return parts;
}
