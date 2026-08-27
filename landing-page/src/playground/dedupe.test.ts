// Drift gate for `vite.resolve.dedupe` in astro.config.mjs.
//
// Two copies of `@codemirror/state` in one bundle do not merely waste bytes:
// CodeMirror keeps module-level singletons, so an extension minted by one copy
// is unrecognisable to the other and `EditorState.create` throws before the
// editor draws. That outage happened once already, and the config's own comment
// says the durable fix is that "the entry has to exist *before* the import that
// would duplicate it" — a rule with, until now, nothing enforcing it.
//
// So: every `@codemirror/*` and `@lezer/*` package this app depends on directly
// must be listed. Extra entries are fine and deliberate; a missing one is the
// bug, and it is invisible until a transitive range drifts.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const read = (relPath: string): string => readFileSync(join(here, relPath), 'utf8');

/** Direct dependencies whose duplication would split a CodeMirror singleton. */
function singletonDeps(): string[] {
  const pkg = JSON.parse(read('../../package.json')) as {
    dependencies?: Record<string, string>;
  };
  return Object.keys(pkg.dependencies ?? {})
    .filter((name) => name.startsWith('@codemirror/') || name.startsWith('@lezer/'))
    .sort();
}

/**
 * The `dedupe` array, read out of the config as text.
 *
 * Importing the config would drag in Astro, the markdown processor and
 * `@sjon/highlight`; reading it is also the stricter check, because a deleted
 * array reports as a missing block rather than as `undefined`.
 */
function dedupeList(): string[] {
  const config = read('../../astro.config.mjs');
  const block = /dedupe:\s*\[([^\]]*)\]/.exec(config);
  assert.ok(block, 'astro.config.mjs no longer declares vite.resolve.dedupe');
  return [...(block[1] ?? '').matchAll(/'([^']+)'/g)].map((m) => m[1] as string);
}

test('every CodeMirror and Lezer dependency is deduped', () => {
  const listed = new Set(dedupeList());
  const missing = singletonDeps().filter((name) => !listed.has(name));
  assert.deepEqual(
    missing,
    [],
    `add these to vite.resolve.dedupe in astro.config.mjs: ${missing.join(', ')}`,
  );
});

test('the dedupe list is not empty', () => {
  // A list emptied rather than deleted would pass the test above vacuously the
  // day the last direct dependency moves behind the `codemirror` meta-package.
  assert.ok(dedupeList().length > 0, 'vite.resolve.dedupe is empty');
});
