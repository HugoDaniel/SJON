// Parser structural recovery — both halves of the split.
//
// `Parser.zig`'s contract is "trees always exist after parse (possibly
// partial); collection over abort". This port honours it for the three
// structural deviations and still throws on the rest (see the header of
// `src/parser.ts`). That split is deliberate but invisible: nothing in
// the corpus reaches the throwing sites, so a later "simplification"
// could delete a recovery arm, or a later recovery addition could land
// without the corpus case that would prove it works.
//
// So this file pins BOTH halves. The recovering sites assert the tree
// that comes back and the diagnostic that describes it; the throwing
// sites assert they still throw. A throwing site that gains recovery
// should fail here — and the fix is to move it up, with a corpus case,
// not to relax the assertion.
//
// The recovery arms are additionally pinned cross-host by
// `conformance/cases/parse-unclosed-form` and
// `conformance/cases/parse-recovery-continues`; these tests are the
// unit-level view of the same behaviour, plus the negative space the
// corpus cannot express.

import { test } from 'node:test';
import * as assert from 'node:assert/strict';

import { parse, ParseError } from '../src/parser.ts';
import type { Diagnostic } from '../src/diagnostics.ts';

function parseWithDiags(src: string): { roots: readonly unknown[]; diags: Diagnostic[] } {
  const diags: Diagnostic[] = [];
  const roots = parse(src, diags);
  return { roots, diags };
}

test('recovery: a form left open at end of input is closed and reported', () => {
  const { roots, diags } = parseWithDiags('(pt :x 1');
  assert.equal(roots.length, 1, 'the recovered form is still a root');
  assert.equal(diags.length, 1);
  assert.equal(diags[0]?.code, 'unspecified');
  assert.equal(diags[0]?.severity, 'err');
  assert.deepEqual(diags[0]?.path, ['pt'], 'attributed to the form left open');

  // The recovered form is complete, not a stub: `:x 1` was attached
  // before the frame closed. This is what `parse-unclosed-form` proves
  // cross-host by way of a required key.
  const form = roots[0] as { tag: string; head: string; children: readonly { tag: string }[] };
  assert.equal(form.tag, 'form');
  assert.equal(form.head, 'pt');
  assert.equal(form.children.length, 1);
  assert.equal(form.children[0]?.tag, 'kvpair');
});

test('recovery: nested open frames report innermost-first, each with its own path', () => {
  const { diags } = parseWithDiags('(pt :x [1 2');
  assert.equal(diags.length, 2);
  // `closeUnclosedFrames` emits before popping, so the innermost frame
  // is described first and its path still names every enclosing frame.
  assert.deepEqual(diags[0]?.path, ['pt', 'x'], 'the vector, named by its kvpair key');
  assert.deepEqual(diags[1]?.path, ['pt'], 'then the form that held it');
});

test('recovery: a vector left open at end of input is closed and reported', () => {
  const { roots, diags } = parseWithDiags('[1 2');
  assert.equal(roots.length, 1);
  assert.equal(diags.length, 1);
  assert.equal(diags[0]?.code, 'unspecified');
  const vec = roots[0] as { tag: string; elements: readonly unknown[] };
  assert.equal(vec.tag, 'vector');
  assert.equal(vec.elements.length, 2, 'elements parsed before EOF are kept');
});

test('recovery: a stray close delimiter is skipped and the roots after it survive', () => {
  const { roots, diags } = parseWithDiags('(a)\n)\n(b)');
  assert.equal(diags.length, 1);
  assert.equal(diags[0]?.code, 'unspecified');
  assert.deepEqual(diags[0]?.path, [], 'a top-level stray delimiter belongs to no form');
  // Both roots, not just the one before the error — the half of
  // "collection over abort" a bare did-it-throw check would miss.
  assert.equal(roots.length, 2);
  assert.deepEqual(
    roots.map((r) => (r as { head: string }).head),
    ['a', 'b'],
  );
});

test('recovery: path attribution does not leak a sibling key onto the next form', () => {
  // Regression: the pending step a parent leaves for its child was
  // previously cleared only when the child opened a frame, so the key
  // of a *scalar*-valued kvpair (`:type number`) survived to prefix the
  // next form's path — `(pt …)` reported as `[type pt]`.
  const { diags } = parseWithDiags('(k :type number)\n(pt :x 1');
  assert.equal(diags.length, 1);
  assert.deepEqual(diags[0]?.path, ['pt']);
});

// --- Still-throwing sites -------------------------------------------
// Not yet at parity with `Parser.zig`, which recovers from these too.
// Each assertion is a marker, not an endorsement: adding recovery here
// means updating this test AND adding the corpus case that proves the
// four hosts agree on the result.

test('no recovery yet: an unterminated string throws', () => {
  assert.throws(() => parse('(a "unterminated'), ParseError);
});

test('no recovery yet: an invalid number literal throws', () => {
  // A bare `-` enters `parseNumber` and leaves `Number.parseFloat` with
  // nothing to read. (`1.2.3` does NOT reach this arm — parseFloat
  // stops at the second dot and returns 1.2, so the port silently
  // accepts it where the Zig lexer would not. That divergence is
  // separate from recovery and is not what this file pins.)
  assert.throws(() => parse('(a -)'), ParseError);
});

test('no recovery yet: a close delimiter mismatching its opener throws', () => {
  assert.throws(() => parse('[1 2)'), ParseError);
});
