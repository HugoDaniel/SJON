// Tests for the lesson transforms (lesson-transforms.ts) and the quiz data
// they render.
//
// These four functions used to live inside a hand-run generator whose output
// was committed, so the only thing that ever checked them was a human reading
// fifteen `content.md` files. They run at build time now, which is why they
// are worth pinning: a regex that stops matching produces a page that looks
// plausible and is wrong — a leftover `# 01 - …` heading, a Goal section the
// sidebar already says, a Mastery Check that is still a bullet list.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  injectPlaygroundLinks,
  replaceMasteryCheck,
  stripLessonFrame,
  transformLesson,
  wrapCodesTable,
} from './lesson-transforms.ts';
import { MASTERY_QUIZZES } from '../data/mastery-quizzes.ts';
import { LESSONS } from './lessons.ts';

const here = dirname(fileURLToPath(import.meta.url));
const tutorialSource = (stem: string): string =>
  readFileSync(join(here, '..', '..', '..', 'docs', 'tutorial', `${stem}.md`), 'utf8');

// ----- stripLessonFrame -----------------------------------------------------

test('stripLessonFrame drops the numbered H1', () => {
  const out = stripLessonFrame('# 01 - Orientation\n\nBody text.\n');
  assert.equal(out, 'Body text.\n');
});

test('stripLessonFrame drops the Goal section up to the next H2', () => {
  const out = stripLessonFrame(
    ['# 03 - Atoms', '', '## Goal', '', 'Know the atoms.', '', '## Symbols', '', 'Body.', ''].join(
      '\n',
    ),
  );
  assert.equal(out, '## Symbols\n\nBody.\n');
});

test('stripLessonFrame leaves a body with neither H1 nor Goal alone', () => {
  assert.equal(stripLessonFrame('## Symbols\n\nBody.\n'), '## Symbols\n\nBody.\n');
});

test('stripLessonFrame does not derive a title', () => {
  // Titles come from lessons.ts, which disagrees with the source H1s on
  // purpose: `02-first-document.md` is headed "First Document" and renders as
  // "Your first document". A transform that synthesised titles from H1s would
  // quietly retitle fifteen pages.
  const source = tutorialSource('02-first-document');
  assert.match(source, /^#\s+02\s*-\s*First Document\s*$/m);
  assert.equal(
    LESSONS.find((l) => l.sourceStem === '02-first-document')?.title,
    'Your first document',
  );
  assert.doesNotMatch(stripLessonFrame(source), /First Document/);
});

// ----- injectPlaygroundLinks ------------------------------------------------

test('injectPlaygroundLinks appends a base64url deep link per sjon fence', () => {
  const out = injectPlaygroundLinks('```sjon\n(camera :ortho)\n```\n');
  const encoded = Buffer.from('(camera :ortho)', 'utf8').toString('base64url');
  assert.ok(out.includes(`[Open in playground →](/playground#s=${encoded})`));
  assert.ok(out.startsWith('```sjon\n(camera :ortho)\n```'), 'the fence itself survives');
});

test('injectPlaygroundLinks ignores fences in other languages', () => {
  const zig = '```zig\nconst x = 1;\n```\n';
  assert.equal(injectPlaygroundLinks(zig), zig);
});

test('injectPlaygroundLinks still fires on a fence carrying Expressive Code meta', () => {
  const encoded = Buffer.from('(camera :ortho)', 'utf8').toString('base64url');
  for (const meta of ['title="scene.sjon"', 'del={1}', 'ins="evenodd" frame="none"']) {
    const out = injectPlaygroundLinks(`\`\`\`sjon ${meta}\n(camera :ortho)\n\`\`\`\n`);
    assert.ok(
      out.includes(`[Open in playground →](/playground#s=${encoded})`),
      `meta \`${meta}\` must not swallow the deep link`,
    );
  }
});

test('injectPlaygroundLinks does not match a language that merely starts with sjon', () => {
  const other = '```sjonnet\n{}\n```\n';
  assert.equal(injectPlaygroundLinks(other), other);
});

// ----- replaceMasteryCheck --------------------------------------------------

const MASTERY_BODY = [
  'Body.',
  '',
  '## Mastery Check',
  '',
  '- Can you say why?',
  '',
  'Back to the [course map](README.md).',
  '',
].join('\n');

test('replaceMasteryCheck swaps the checklist for the scored quiz', () => {
  const out = replaceMasteryCheck(MASTERY_BODY, 'orientation');
  assert.ok(out.startsWith('Body.\n'));
  assert.match(out, /<section class="mastery-quiz" data-lesson="orientation">/);
  assert.match(out, /class="mc-item" data-correct="\d+"/);
  assert.doesNotMatch(out, /Can you say why\?/);
});

test('replaceMasteryCheck truncates everything after the heading', () => {
  // This is what removes each lesson's trailing `Next:` line — and lesson 15's
  // `Back to the [course map](README.md)`, which has no page on this site. The
  // `Next:` regex in stripLessonFrame gets the credit and rarely does the work.
  const out = replaceMasteryCheck(MASTERY_BODY, 'orientation');
  assert.doesNotMatch(out, /course map/);
});

test('replaceMasteryCheck drops the section when the lesson has no questions', () => {
  const out = replaceMasteryCheck(MASTERY_BODY, 'no-such-lesson');
  assert.equal(out, 'Body.\n');
});

test('replaceMasteryCheck leaves a body with no Mastery Check alone', () => {
  assert.equal(replaceMasteryCheck('Body.\n', 'orientation'), 'Body.\n');
});

// ----- wrapCodesTable -------------------------------------------------------

test('wrapCodesTable wraps the table and keeps the blank lines around it', () => {
  const body = [
    'Prose.',
    '',
    '| Code | Meaning |',
    '| --- | --- |',
    '| a | b |',
    '',
    'After.',
  ].join('\n');
  const out = wrapCodesTable(body);
  assert.ok(out.includes('<div class="codes-sticky">\n\n| Code | Meaning |'));
  // Blank lines are load-bearing: without them the markdown processor stops
  // recognising the GFM table inside the raw HTML block.
  assert.ok(out.includes('| a | b |\n\n</div>'));
  assert.ok(out.endsWith('After.'));
});

test('wrapCodesTable is a no-op when there is no codes table', () => {
  assert.equal(wrapCodesTable('Prose.\n\nMore.\n'), 'Prose.\n\nMore.\n');
});

// ----- transformLesson ------------------------------------------------------

test('transformLesson deep-links the early lessons and not the later ones', () => {
  const fence = '```sjon\n(camera :ortho)\n```\n';
  const early = transformLesson(`# 01 - X\n\n${fence}`, { num: 1, slug: 'orientation' });
  const late = transformLesson(`# 09 - X\n\n${fence}`, { num: 9, slug: 'reading-plugin-schemas' });
  assert.match(early, /Open in playground/);
  assert.doesNotMatch(late, /Open in playground/);
});

test('transformLesson wraps the codes table only in the diagnostics lesson', () => {
  const table = '| Code | Meaning |\n| --- | --- |\n| a | b |\n\nAfter.\n';
  const wrapped = transformLesson(`# 14 - X\n\n${table}`, {
    num: 14,
    slug: 'diagnostics-driven-repair',
  });
  const plain = transformLesson(`# 13 - X\n\n${table}`, { num: 13, slug: 'cross-references' });
  assert.match(wrapped, /codes-sticky/);
  assert.doesNotMatch(plain, /codes-sticky/);
});

test('every real lesson source transforms into a body with no leftover frame', () => {
  for (const lesson of LESSONS) {
    const out = transformLesson(tutorialSource(lesson.sourceStem), lesson);
    assert.doesNotMatch(out, /^#\s+\d+\s*[-–—]/m, `${lesson.slug} kept its H1`);
    assert.doesNotMatch(out, /^##\s+Goal\b/m, `${lesson.slug} kept its Goal section`);
    assert.doesNotMatch(out, /^Next:\s*\[/m, `${lesson.slug} kept its Next line`);
    assert.match(out, /mastery-quiz/, `${lesson.slug} lost its quiz`);
  }
});

test('the last lesson loses its course-map link', () => {
  // It has no `Next:` line — it signs off with `Back to the [course map]
  // (README.md)`, which is a page this site does not serve.
  const last = LESSONS[LESSONS.length - 1];
  assert.ok(last);
  const source = tutorialSource(last.sourceStem);
  assert.match(source, /course map/, 'the source no longer ends the way this test assumes');
  assert.doesNotMatch(transformLesson(source, last), /course map/);
});

// ----- quiz data ------------------------------------------------------------

test('every lesson has a quiz and every quiz has a lesson', () => {
  const slugs = new Set(LESSONS.map((l) => l.slug));
  assert.deepEqual(
    LESSONS.filter((l) => !MASTERY_QUIZZES[l.slug]).map((l) => l.slug),
    [],
    'lesson with no quiz',
  );
  assert.deepEqual(
    Object.keys(MASTERY_QUIZZES).filter((slug) => !slugs.has(slug)),
    [],
    'quiz with no lesson',
  );
});

test('every answer index points at an option that exists', () => {
  // mastery-quizzes.ts asserts this at import, so reaching this line already
  // proves it. Stated here so the guarantee is visible in the test output and
  // an import-time check is not mistaken for dead code.
  for (const [slug, quiz] of Object.entries(MASTERY_QUIZZES)) {
    quiz.forEach((question, i) => {
      assert.ok(
        question.correct >= 0 && question.correct < question.options.length,
        `${slug}[${i}] answers option ${question.correct} of ${question.options.length}`,
      );
    });
  }
});
