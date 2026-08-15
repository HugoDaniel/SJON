// Remark plugin that rewrites the link patterns appearing in the
// docs/tutorial/*.md sources so they make sense once those documents
// are hosted at /<part>/<chapter>/<lesson> instead of inside the repo.
//
// The migration runs (see step 7 of the implementation plan) lift each
// lesson body verbatim, so links still look like `../AUTHORING.md`,
// `../LANGUAGE.md`, `../../examples/basic.sjon`, or sibling tutorials
// `08-bindings-and-control-flow.md`. This plugin maps each shape to a
// final URL.

import { visit } from 'unist-util-visit';

const REPO_BASE = 'https://github.com/hugodaniel/sjon/blob/main';

// Inter-tutorial sibling links — keyed by the leading numeric prefix
// + slug used in docs/tutorial/. Mirrors the routes set up in
// src/content/tutorial/ + the LessonOutline component.
const LESSON_BY_FILE = Object.freeze({
  '01-orientation': '/foundations/syntax/orientation',
  '02-first-document': '/foundations/syntax/first-document',
  '03-atoms-and-intent': '/foundations/syntax/atoms-and-intent',
  '04-numbers-units-vectors': '/foundations/syntax/numbers-units-vectors',
  '05-forms-and-keyword-pairing': '/foundations/syntax/forms-and-keyword-pairing',
  '06-comments-and-strings': '/foundations/syntax/comments-and-strings',
  '07-safe-expressions': '/foundations/expressions/safe-expressions',
  '08-bindings-and-control-flow': '/foundations/expressions/bindings-and-control-flow',
  '09-reading-plugin-schemas': '/schemas/reading/reading-plugin-schemas',
  '10-discriminated-and-exclusive-forms': '/schemas/reading/discriminated-and-exclusive-forms',
  '11-value-kinds-shapes': '/schemas/reading/value-kinds-shapes',
  '12-value-kinds-refinements': '/schemas/reading/value-kinds-refinements',
  '13-cross-references': '/schemas/reading/cross-references',
  '14-diagnostics-driven-repair': '/schemas/repair/diagnostics-driven-repair',
  '15-style-portability-and-capstone': '/schemas/repair/style-portability-capstone',
});

const SIBLING_RE = /^(\d{2}-[a-z0-9-]+)(?:\.md)?(#.*)?$/;
const PARENT_DOC_RE = /^\.\.\/([A-Za-z0-9_-]+)\.md(#.*)?$/;
const EXAMPLE_RE = /^\.\.\/\.\.\/(examples\/[A-Za-z0-9._/-]+)$/;

function rewriteUrl(url) {
  if (!url || typeof url !== 'string') return url;

  // ../AUTHORING.md, ../LANGUAGE.md, ../DESIGN.md, ../scene-sketch.md, …
  const parent = PARENT_DOC_RE.exec(url);
  if (parent) {
    return `${REPO_BASE}/docs/${parent[1]}.md${parent[2] ?? ''}`;
  }

  // ../../examples/basic.sjon, ../../examples/plugins/shapes.zig, …
  const example = EXAMPLE_RE.exec(url);
  if (example) {
    return `${REPO_BASE}/${example[1]}`;
  }

  // Sibling tutorial: 08-bindings-and-control-flow.md or .../08-…
  const sibling = SIBLING_RE.exec(url);
  if (sibling && LESSON_BY_FILE[sibling[1]]) {
    return `${LESSON_BY_FILE[sibling[1]]}${sibling[2] ?? ''}`;
  }

  return url;
}

const EXTERNAL_OR_ANCHOR = /^[a-z][a-z0-9+.-]*:|^\/\/|^#/i;

export default function sjonLinkRewriter({ base = '/' } = {}) {
  const basePrefix = base.replace(/\/+$/, '');

  function applyBase(url) {
    if (!url || typeof url !== 'string') return url;
    if (basePrefix === '') return url;
    if (EXTERNAL_OR_ANCHOR.test(url)) return url;
    if (url.startsWith('/')) return basePrefix + url;
    return url;
  }

  return (tree) => {
    visit(tree, ['link', 'definition'], (node) => {
      node.url = applyBase(rewriteUrl(node.url));
    });
  };
}
