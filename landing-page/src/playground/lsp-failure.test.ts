// Tests for the LSP boot-failure banner (lsp-failure.ts).
//
// Two halves, and the second is the one that matters. The first drives
// `showLspFailure` directly with a structural stand-in for the element. The
// second checks the wiring the first cannot see: a banner nothing unhides, or
// a `catch` that unhides a banner absent from the markup, both look exactly
// like the bug this feature exists to report — a page that appears healthy
// while every server-fed panel is empty.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  FAILURE_BANNER_SELECTOR,
  FAILURE_REASON_SELECTOR,
  describeLspFailure,
  showLspFailure,
  type FailureBanner,
} from './lsp-failure.ts';

const here = dirname(fileURLToPath(import.meta.url));
const read = (relPath: string): string => readFileSync(join(here, relPath), 'utf8');

/** A banner with a reason slot, in the shape `showLspFailure` consumes. */
function fakeBanner(withSlot = true): FailureBanner & { slot: { textContent: string | null } } {
  const slot = { textContent: null as string | null };
  return {
    slot,
    hidden: true,
    querySelector(selectors: string) {
      return withSlot && selectors === FAILURE_REASON_SELECTOR ? slot : null;
    },
  };
}

test('showLspFailure unhides the banner and names the reason', () => {
  const banner = fakeBanner();
  showLspFailure(banner, new Error('Incorrect response MIME type'));
  assert.equal(banner.hidden, false);
  assert.equal(banner.slot.textContent, 'Incorrect response MIME type');
});

test('showLspFailure still unhides when the reason slot is missing', () => {
  const banner = fakeBanner(false);
  showLspFailure(banner, new Error('boom'));
  assert.equal(banner.hidden, false);
});

test('showLspFailure tolerates a banner that is not in the markup', () => {
  // It runs inside the catch that already lost the language server; throwing
  // here would take the mounted editor down with it.
  assert.doesNotThrow(() => showLspFailure(null, new Error('boom')));
});

test('describeLspFailure reduces any thrown value to one readable line', () => {
  assert.equal(
    describeLspFailure(new Error('Incorrect response MIME type')),
    'Incorrect response MIME type',
  );
  assert.equal(describeLspFailure('plain string'), 'plain string');
  assert.equal(describeLspFailure(new Error('')), 'Error');
  assert.equal(describeLspFailure({ nope: 1 }), 'unknown error');
});

test('the playground markup carries the banner and reason slot boot unhides', () => {
  // Drift gate: the selectors are the whole contract between lsp-failure.ts
  // and playground.astro, and nothing else would notice them parting ways.
  const markup = read('../pages/playground.astro');
  const bannerAttr = FAILURE_BANNER_SELECTOR.slice(1, -1);
  const reasonAttr = FAILURE_REASON_SELECTOR.slice(1, -1);
  assert.ok(markup.includes(bannerAttr), `playground.astro has no ${bannerAttr} element`);
  assert.ok(markup.includes(reasonAttr), `playground.astro has no ${reasonAttr} element`);
  assert.match(
    markup,
    new RegExp(`${bannerAttr}[^>]*\\bhidden\\b`),
    'the banner must start hidden',
  );
});

test('the boot catch reports the failure rather than only logging it', () => {
  const boot = read('boot.ts');
  const catchStart = boot.indexOf('} catch (e) {', boot.indexOf('await initLSP('));
  assert.notEqual(catchStart, -1, 'boot.ts no longer wraps initLSP in a catch');
  const catchBlock = boot.slice(catchStart, boot.indexOf('\n  }', catchStart));
  assert.match(catchBlock, /showLspFailure\(/, 'the LSP boot catch went back to console-only');
});
