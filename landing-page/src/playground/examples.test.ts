// Headless unit tests for the curated example registry. Everything checkable
// without a language server lives here; the "does it still validate" half is
// `scripts/check-examples.mjs`, which needs the real wasm and runs as its own
// build step. Run with `node --test --experimental-strip-types`.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { decodeHashState, encodeHashState } from './hash-state.ts';
import { DEFAULT_EXAMPLE, PLAYGROUND_EXAMPLES } from './examples.ts';

test('every example round-trips through the URL-hash encode/decode', () => {
  for (const example of PLAYGROUND_EXAMPLES) {
    const state = decodeHashState('#' + encodeHashState(example.doc, example.schemas));
    assert.equal(state.doc, example.doc, `${example.id}: document did not survive the hash`);
    assert.deepEqual(state.schemas, example.schemas, `${example.id}: schemas did not survive`);
  }
});

test('every example declares its diagnostics or claims to be clean', () => {
  // The registry half of the contract `check-examples.mjs` enforces against
  // the server: a non-empty `expectDiagnostics` means "this example is a demo
  // of these codes". An empty array would read as "expects diagnostics, names
  // none", which the checker would compare against an empty set and pass —
  // silently turning a clean-document assertion off.
  for (const example of PLAYGROUND_EXAMPLES) {
    if (example.expectDiagnostics === undefined) continue;
    assert.ok(
      example.expectDiagnostics.length > 0,
      `${example.id}: expectDiagnostics is empty — omit it to assert the example is clean`,
    );
  }
});

test('example ids are unique and URL-safe', () => {
  const seen = new Set<string>();
  for (const example of PLAYGROUND_EXAMPLES) {
    assert.ok(!seen.has(example.id), `duplicate example id: ${example.id}`);
    seen.add(example.id);
    assert.match(example.id, /^[a-z0-9-]+$/, `${example.id}: not a URL-safe id`);
  }
});

test('every example carries the copy the picker needs', () => {
  for (const example of PLAYGROUND_EXAMPLES) {
    assert.ok(example.title.length > 0, `${example.id}: missing title`);
    assert.ok(example.blurb.length > 0, `${example.id}: missing blurb`);
    assert.ok(example.doc.trim().length > 0, `${example.id}: empty document`);
  }
});

test('the default example is the first entry and needs no schema', () => {
  assert.equal(DEFAULT_EXAMPLE, PLAYGROUND_EXAMPLES[0]);
  // The playground opens on it before any schema pane exists, so an entry
  // needing schemas would render its own document as a wall of unknown_form.
  assert.deepEqual(DEFAULT_EXAMPLE.schemas, []);
  assert.equal(DEFAULT_EXAMPLE.expectDiagnostics, undefined);
});
