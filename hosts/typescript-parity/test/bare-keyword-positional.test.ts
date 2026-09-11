// A keyword the parser could not pair (plan LSP/22). `(lane :name)` earns
// `positional_not_allowed` because the greedy pairing rule turns `:name`
// with nothing after it into a bare keyword *value*, and the plain
// message ("does not accept positional children") gives an author no way
// to work that out. Both walkers append a tail naming the keyword.
//
// The corpus pins `(code, path)` and never a message, so a host's prose
// is only ever pinned here.

import test from 'node:test';
import assert from 'node:assert';

import { validateDocument } from '../src/Host.ts';

const MANIFEST = `
(plugin :name demo :version "1.0.0"
  (form :name scene))
`;

/** The first `positional_not_allowed` error's message, or null. */
function positionalMessage(doc: string): string | null {
  const r = validateDocument(`${MANIFEST}\n${doc}\n`, {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  const d = r.diagnostics.find((e) => e.severity === 'err' && e.code === 'positional_not_allowed');
  return d ? d.message : null;
}

test('a bare keyword positional says the keyword has no value', () => {
  assert.strictEqual(
    positionalMessage('(scene :name)'),
    'form `scene` does not accept positional children — `:name` has no value, so it is a bare keyword, not a keyword pair',
  );
});

test('the tail is not only for a trailing keyword', () => {
  // `:ortho` is followed by another keyword, so pairing leaves it bare
  // there too. `:zoom 2` does pair, and earns `unknown_key` instead.
  assert.strictEqual(
    positionalMessage('(scene :ortho :zoom 2)'),
    'form `scene` does not accept positional children — `:ortho` has no value, so it is a bare keyword, not a keyword pair',
  );
});

test('every other positional keeps the plain message', () => {
  assert.strictEqual(
    positionalMessage('(scene 42)'),
    'form `scene` does not accept positional children',
  );
});
