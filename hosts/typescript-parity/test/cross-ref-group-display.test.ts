// A multi-target cross-ref's target text (plan LSP/19). The registry key
// for `(cross-ref :target [a b])` is the canonical names joined with a
// *space* — an identity string, not something to show a reader — so both
// hosts rendered a form whose head contained a space. `describeBucket`
// gives it the ` | ` the hover cards already use.
//
// The corpus pins `(code, path)` and never a message, so a host's target
// text is only ever pinned here.

import test from 'node:test';
import assert from 'node:assert';

import { validateDocument } from '../src/Host.ts';

const GROUP_MANIFEST = `
(plugin :name xref :version "1.0.0"
  (value-kind :name pipeline-ref :underlying symbol
    :cross-ref (cross-ref :target [render-pipeline compute-pipeline]))
  (form :name render-pipeline (key :name name :type symbol))
  (form :name compute-pipeline (key :name name :type symbol))
  (form :name dispatch (key :name pipeline :type pipeline-ref :optional true)))
`;

const SINGLE_MANIFEST = `
(plugin :name demo :version "1.0.0"
  (value-kind :name phrase-name :underlying symbol
    :cross-ref (cross-ref :target phrase))
  (form :name phrase (key :name name :type symbol))
  (form :name ref (key :name k :type phrase-name :optional true)))
`;

/** The first `code` error's message, behind `manifest`. */
function messageFor(manifest: string, doc: string, code: string): string {
  const r = validateDocument(`${manifest}\n${doc}\n`, {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  const d = r.diagnostics.find((e) => e.severity === 'err' && e.code === code);
  assert.ok(d, `no ${code} diagnostic`);
  return d.message;
}

test('not_cross_ref names a group as a disjunction', () => {
  const msg = messageFor(
    GROUP_MANIFEST,
    '(render-pipeline :name blit)\n(compute-pipeline :name reduce)\n(dispatch :pipeline blot)',
    'not_cross_ref',
  );
  // The *target* converges on Zig's: canonical, sorted, ` | `-joined. The
  // surrounding sentence does not, and is not meant to — Zig reads
  // "got `blot` (no `(… :name …)` form declares this name)". That is the
  // standing `MatchFail` message-protocol divergence (plan 18's CP2), and
  // a pin that did not say so would read as a claim of full parity.
  assert.ok(
    msg.includes('`xref/compute-pipeline | xref/render-pipeline`'),
    `target not rendered as a group: ${msg}`,
  );
});

test('not_cross_ref names a single target by its canonical name', () => {
  // Was the *bare* head (`phrase`), where Zig has always named the bucket
  // (`demo/phrase`). A host disagreement older than the group finding.
  const msg = messageFor(SINGLE_MANIFEST, '(phrase :name p)\n(ref :k missing)', 'not_cross_ref');
  assert.ok(msg.includes('`demo/phrase`'), `target not canonical: ${msg}`);
});

test('duplicate_cross_ref_target says `across forms` for a group', () => {
  const msg = messageFor(
    GROUP_MANIFEST,
    '(render-pipeline :name same)\n(compute-pipeline :name same)',
    'duplicate_cross_ref_target',
  );
  // Byte-identical to Zig's: this message has no `MatchFail` protocol
  // between the two hosts, so nothing stops it converging completely.
  assert.strictEqual(
    msg,
    'duplicate cross-ref name `same` across forms `xref/compute-pipeline | xref/render-pipeline`',
  );
});

test('duplicate_cross_ref_target says `on form` for a single target', () => {
  // Was `on form \`phrase\`` — the bare head of whichever form sat at the
  // span, rather than the bucket the collision actually belongs to.
  const msg = messageFor(
    SINGLE_MANIFEST,
    '(phrase :name same)\n(phrase :name same)',
    'duplicate_cross_ref_target',
  );
  assert.strictEqual(msg, 'duplicate cross-ref name `same` on form `demo/phrase`');
});
