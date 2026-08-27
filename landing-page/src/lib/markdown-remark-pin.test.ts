// Drift gate for the `@astrojs/markdown-remark` pin.
//
// `astro.config.mjs` builds `markdown.processor` by calling `unified()`
// imported from `@astrojs/markdown-remark`, and hangs the link rewriter off
// it. Astro then reads that processor back and Starlight pushes its own
// plugins onto it. All of which only works while the config's copy of the
// package and Astro's copy are the *same* copy: `unified()` from a second
// instance produces a processor Astro does not recognise as its own, so the
// rewriter silently stops running and every tutorial link loses its `base`.
// The build stays green. The site ships with broken links.
//
// The tree really does want to split here. `astro@7.1.6` declares an exact
// *peer* on `@astrojs/markdown-remark`, while `@astrojs/mdx@7.0.7` declares an
// exact *dependency* on a different patch, so pnpm installs two copies by
// default and only the workspace-root `pnpm.overrides` entry collapses them.
// (Collapsing them is safe: it was verified to leave all 151 built pages
// byte-identical.) `vite.resolve.dedupe` cannot do this job — it governs what
// Vite bundles for the browser, not what Node resolves when it loads
// `astro.config.mjs`.
//
// So this asserts the override exists and still agrees with both ends. Bump
// Astro to a version peering a different patch and this goes red, which is the
// moment to move the override and the dependency together.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const PACKAGE = '@astrojs/markdown-remark';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..', '..');

const readJson = (path: string): Record<string, unknown> =>
  JSON.parse(readFileSync(path, 'utf8')) as Record<string, unknown>;

/** The version every copy in the tree is forced to. */
function overridePin(): string | undefined {
  const root = readJson(join(repoRoot, 'package.json'));
  const pnpm = root['pnpm'] as { overrides?: Record<string, string> } | undefined;
  return pnpm?.overrides?.[PACKAGE];
}

/** What `landing-page` itself asks for, which is what `astro.config.mjs` imports. */
function declaredDependency(): string | undefined {
  const pkg = readJson(join(repoRoot, 'landing-page', 'package.json'));
  const deps = pkg['dependencies'] as Record<string, string> | undefined;
  return deps?.[PACKAGE];
}

/**
 * What the installed Astro peer-requires.
 *
 * Read out of `node_modules` rather than transcribed, because the whole point
 * is to notice when an Astro bump moves it.
 */
function astroPeerRange(): string | undefined {
  const require = createRequire(join(repoRoot, 'landing-page', 'package.json'));
  const astro = readJson(require.resolve('astro/package.json'));
  const peers = astro['peerDependencies'] as Record<string, string> | undefined;
  return peers?.[PACKAGE];
}

test('the workspace root pins a single markdown-remark for the whole tree', () => {
  assert.ok(
    overridePin(),
    `package.json is missing pnpm.overrides['${PACKAGE}'] — without it pnpm installs two copies and the link rewriter stops running silently`,
  );
});

test('the pin, the landing-page dependency and Astro’s peer all agree', () => {
  const pin = overridePin();
  assert.equal(
    declaredDependency(),
    pin,
    "landing-page's dependency has drifted from the workspace override",
  );
  assert.equal(
    astroPeerRange(),
    pin,
    'Astro now peer-requires a different markdown-remark: move the override and the landing-page dependency to match it, together',
  );
});
