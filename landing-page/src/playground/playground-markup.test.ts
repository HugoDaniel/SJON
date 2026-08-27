// Drift gate for the playground's page markup.
//
// Every panel the language server feeds is wired up by a `querySelector` in
// one of the modules here, and every one of those lookups sits behind an
// `if (el)` guard that no-ops when the element is absent. That is the right
// behaviour — a missing outline strip should not take the editor down with it
// — and it is also exactly the failure the LSP banner exists to report: a
// page that mounts, highlights, looks completely fine, and has empty panels
// forever. Nothing but a reader noticing would catch it.
//
// So the selectors are read out of the modules themselves rather than
// transcribed here. A hook added to the code and forgotten in the markup fails
// this test, and a list that goes stale is not a thing that can happen.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const read = (relPath: string): string => readFileSync(join(here, relPath), 'utf8');

const markup = read('../pages/playground.astro');

/** Every `[data-pg-…]` selector the playground modules query for. */
function queriedSelectors(): string[] {
  const found = new Set<string>();
  for (const file of readdirSync(here)) {
    if (!file.endsWith('.ts') || file.endsWith('.test.ts')) continue;
    for (const m of read(file).matchAll(/\[data-pg-[a-z-]+(?:="[a-z-]+")?\]/g)) {
      found.add(m[0]);
    }
  }
  return [...found].sort();
}

test('the modules query for a non-trivial number of hooks', () => {
  // Guards the guard: a regex that stopped matching would make every
  // assertion below pass over an empty list.
  assert.ok(queriedSelectors().length >= 12, 'the selector scan found almost nothing');
});

test('every hook the playground queries for exists in the markup', () => {
  const missing = queriedSelectors().filter((selector) => {
    // `[data-pg-tab="document"]` has to match an element carrying both, not
    // the attribute and the value in different places.
    const valued = /^\[([a-z-]+)="([a-z-]+)"\]$/.exec(selector);
    if (valued) return !new RegExp(`${valued[1]}="${valued[2]}"`).test(markup);
    return !markup.includes(selector.slice(1, -1));
  });
  assert.deepEqual(missing, [], 'playground.astro is missing hooks the code looks for');
});

test('the editor mount point matches what the page script looks up', () => {
  // The one lookup with no `if (el)` fallback worth having: no mount, no
  // editor, and `mountPlayground` is never called at all.
  assert.match(markup, /id="sjon-editor"/);
  assert.match(markup, /getElementById\('sjon-editor'\)/);
  // `mountPlayground` walks up to the frame and throws without it.
  assert.match(markup, /class="editor-frame/);
  assert.match(read('boot.ts'), /host\.closest\('\.editor-frame'\)/);
});

test('the panels that start collapsed carry `hidden` in their opening tag', () => {
  // Each of these is unhidden by script. Without the attribute they are
  // visible and empty on first paint; the `hidden` has to be in the same
  // opening tag as the hook, which is what these patterns check.
  for (const attr of ['data-pg-stale', 'data-pg-lsp-failed', 'data-pg-outline']) {
    assert.match(markup, new RegExp(`${attr}[^>]*\\bhidden\\b`), `${attr} must start hidden`);
  }
});

test('the example picker offers every example', () => {
  // The picker is built from `PLAYGROUND_EXAMPLES`, plus one hidden "Custom"
  // placeholder that the closed picker falls back to once an edited document
  // stops matching any example. Losing that placeholder leaves the control
  // showing a stale example name.
  assert.match(markup, /PLAYGROUND_EXAMPLES\.map/);
  assert.match(markup, /<option value="" hidden>Custom<\/option>/);
});

test('the editor subtree opts out of Starlight prose styling and search', () => {
  // `.sl-markdown-content` reaches every descendant, so the frame needs
  // `not-content`; without it the editor chrome is restyled as prose.
  // `data-pagefind-ignore` keeps the shell out of the search index.
  assert.match(markup, /class="editor-frame not-content"/);
  assert.match(markup, /data-pagefind-ignore/);
});

test('the page is a splash template, which is what removes the sidebar and ToC', () => {
  // `hasSidebar: false` alone leaves a 300px table-of-contents column claiming
  // space for one entry; splash is the flag that turns off both.
  assert.match(markup, /template: 'splash'/);
});
