// Remark plugin that rewrites the link shapes appearing in the
// docs/tutorial/*.md sources so they still mean something once those
// documents are served at /<part>/<chapter>/<lesson> instead of read
// inside the repo.
//
// The lesson bodies are lifted verbatim, so their links still look like
// `../AUTHORING.md`, `../../examples/basic.sjon`, a sibling tutorial
// `08-bindings-and-control-flow.md`, or `README.md` for the course map.
// This plugin maps each shape to a final URL, then applies Astro's `base`.

import { visit } from 'unist-util-visit';
import { LESSONS } from '../src/lib/lessons.ts';

// The public mirror. Note the path shape: gitea serves a file at
// `<owner>/<repo>/src/branch/<ref>/<path>`, which is not GitHub's
// `blob/<ref>` — swapping the host alone would 404 every one of these.
const REPO_BASE = 'https://git.hugodaniel.com/releases/sjon/src/branch/main';

// Inter-tutorial sibling links, keyed by the source filename's stem.
// Derived rather than transcribed: this used to be a third hand-kept copy
// of the lesson table, and a rename that missed it degraded silently into
// an un-rewritten link.
const LESSON_BY_FILE = Object.freeze(
  Object.fromEntries(LESSONS.map((lesson) => [lesson.sourceStem, lesson.route])),
);

const SIBLING_RE = /^(\d{2}-[a-z0-9-]+)(?:\.md)?(#.*)?$/;
const PARENT_DOC_RE = /^\.\.\/([A-Za-z0-9_-]+)\.md(#.*)?$/;
const EXAMPLE_RE = /^\.\.\/\.\.\/(examples\/[A-Za-z0-9._/-]+)$/;
// Any other `.md` beside the lessons in docs/tutorial/ — today just the
// course map, `README.md`, which lesson 15 signs off with. There is no page
// for it on the site, and the repo file is the thing it names, so it gets
// the same treatment as `../AUTHORING.md`.
const TUTORIAL_SIBLING_RE = /^([A-Za-z0-9_-]+\.md)(#.*)?$/;

function rewriteUrl(url) {
  if (!url || typeof url !== 'string') return url;

  // ../AUTHORING.md, ../LANGUAGE.md, ../SCHEMA_EXPORT.md#calling-the-exporter, …
  const parent = PARENT_DOC_RE.exec(url);
  if (parent) {
    return `${REPO_BASE}/docs/${parent[1]}.md${parent[2] ?? ''}`;
  }

  // ../../examples/basic.sjon, ../../examples/plugins/README.md, …
  const example = EXAMPLE_RE.exec(url);
  if (example) {
    return `${REPO_BASE}/${example[1]}`;
  }

  // Sibling tutorial: 08-bindings-and-control-flow.md or .../08-…
  const sibling = SIBLING_RE.exec(url);
  if (sibling && LESSON_BY_FILE[sibling[1]]) {
    return `${LESSON_BY_FILE[sibling[1]]}${sibling[2] ?? ''}`;
  }

  const tutorialSibling = TUTORIAL_SIBLING_RE.exec(url);
  if (tutorialSibling) {
    return `${REPO_BASE}/docs/tutorial/${tutorialSibling[1]}${tutorialSibling[2] ?? ''}`;
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
