// Renders a lesson's mastery quiz as raw HTML.
//
// Raw HTML rather than an Astro component on purpose: the lesson bodies are
// `.md` rendered to an HTML string by the content layer, so there is no seam
// to mount a component into (`<Content components={…}>` is MDX-only). What
// this emits is a class contract shared with two other files and nothing
// else: `public/mastery-quiz.js` scores it, and `src/styles/mastery-quiz.css`
// paints it. Change a class name here and both must move with it.

import { MASTERY_QUIZZES, type QuizQuestion } from '../data/mastery-quizzes.ts';

const HTML_ESCAPES: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
};

function escapeHtml(text: string): string {
  return text.replace(/[&<>"]/g, (c) => HTML_ESCAPES[c] ?? c);
}

/**
 * Inline markdown → HTML for the subset that appears in quiz prose: code
 * spans, `**strong**`, `*em*`.
 *
 * Not a markdown parser, and it does not need to be. This output is embedded
 * as raw HTML inside a markdown document, so the markdown processor leaves it
 * alone — which means anything it does not handle here stays literal rather
 * than being picked up downstream. Everything else is escaped first, so no
 * text in the quiz data can open a tag.
 */
export function inlineMdToHtml(s: string): string {
  let out = '';
  let i = 0;
  while (i < s.length) {
    const ch = s[i];
    if (ch === '`') {
      const end = s.indexOf('`', i + 1);
      if (end !== -1) {
        out += `<code>${escapeHtml(s.slice(i + 1, end))}</code>`;
        i = end + 1;
        continue;
      }
    }
    if (ch === '*' && s[i + 1] === '*') {
      const end = s.indexOf('**', i + 2);
      if (end !== -1) {
        out += `<strong>${inlineMdToHtml(s.slice(i + 2, end))}</strong>`;
        i = end + 2;
        continue;
      }
    }
    if (ch === '*') {
      const end = s.indexOf('*', i + 1);
      if (end !== -1) {
        out += `<em>${inlineMdToHtml(s.slice(i + 1, end))}</em>`;
        i = end + 1;
        continue;
      }
    }
    out += escapeHtml(ch as string);
    i++;
  }
  return out;
}

function renderOption(question: QuizQuestion, name: string, opt: string, j: number): string {
  const expl = question.explanations?.[j];
  const explLine = expl
    ? `        <p class="mc-explanation" hidden>${inlineMdToHtml(expl)}</p>`
    : null;
  return [
    '      <li>',
    `        <label><input type="radio" name="${name}" value="${j}" /> <span>${inlineMdToHtml(opt)}</span></label>`,
    ...(explLine ? [explLine] : []),
    '      </li>',
  ].join('\n');
}

function renderQuestion(question: QuizQuestion, lessonSlug: string, i: number): string {
  const name = `q-${lessonSlug}-${i}`;
  const opts = question.options.map((opt, j) => renderOption(question, name, opt, j)).join('\n');
  return [
    `    <li class="mc-item" data-correct="${question.correct}">`,
    `      <p class="mc-q">${inlineMdToHtml(question.q)}</p>`,
    '      <ul class="mc-options">',
    opts,
    '      </ul>',
    '      <p class="mc-feedback" hidden></p>',
    '    </li>',
  ].join('\n');
}

/**
 * The `<section class="mastery-quiz">` block for one lesson, or `null` when
 * that lesson has no questions.
 *
 * `null` rather than an empty section: the caller drops the whole Mastery
 * Check section in that case, which is better than a heading with nothing
 * under it and a Submit button that scores zero of zero.
 */
export function renderQuizHtml(lessonSlug: string): string | null {
  const quiz = MASTERY_QUIZZES[lessonSlug];
  if (!quiz || quiz.length === 0) return null;

  const items = quiz.map((question, i) => renderQuestion(question, lessonSlug, i)).join('\n');

  return [
    '',
    `<section class="mastery-quiz" data-lesson="${lessonSlug}">`,
    '  <h2>Mastery Check</h2>',
    '  <ol class="mc-list">',
    items,
    '  </ol>',
    '  <div class="mc-controls">',
    '    <button type="button" class="mc-submit">Submit answers</button>',
    '    <button type="button" class="mc-reset" hidden>Reset</button>',
    '    <p class="mc-score" hidden></p>',
    '  </div>',
    '</section>',
    '',
  ].join('\n');
}
