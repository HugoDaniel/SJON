// A typed-vector element failure spans the element, not the vector (plan
// LSP/18). The corpus compares `(code, path)` and never a span, so this
// family's spans and its `element [N]: ` message wrap are only ever pinned
// by a host's own tests — which is how the TS port's `element ${idx}: `
// (no brackets) went unnoticed against Zig's `element [${idx}]: `.

import test from 'node:test';
import assert from 'node:assert';

import { validateDocument } from '../src/Host.ts';

const MANIFEST = `
(plugin :name demo :version "1.0.0"
  (value-kind :name vec4 :underlying vector
    :vector (vector-shape :element number :len 4))
  (value-kind :name mat4 :underlying vector
    :vector (vector-shape :element vec4 :len 4))
  (value-kind :name ints :underlying vector
    :vector (vector-shape :element number))
  (form :name set
    (key :name m :type mat4 :optional true)
    (key :name v :type ints :optional true)))
`;

/** Validate `doc` behind the manifest, and report spans against the whole
 *  source the validator actually saw — the manifest prefix included. */
function errsFor(doc: string) {
  const src = `${MANIFEST}\n${doc}\n`;
  const r = validateDocument(src, {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  return { src, errs: r.diagnostics.filter((d) => d.severity === 'err') };
}

/** The source text the first `code` diagnostic covers. */
function spanTextOf(doc: string, code: string): string {
  const { src, errs } = errsFor(doc);
  const d = errs.find((e) => e.code === code);
  assert.ok(d, `no ${code} in ${JSON.stringify(errs.map((e) => e.code))}`);
  return src.slice(d.span.start, d.span.end);
}

/** The message of the first `code` diagnostic. */
function messageOf(doc: string, code: string): string {
  const { errs } = errsFor(doc);
  const d = errs.find((e) => e.code === code);
  assert.ok(d, `no ${code} in ${JSON.stringify(errs.map((e) => e.code))}`);
  return d.message;
}

test('a typed-vector element failure spans the element', () => {
  assert.strictEqual(spanTextOf('(set :v [1 "two" 3])', 'wrong_underlying'), '"two"');
});

test('a doubly-nested element failure spans the innermost leaf', () => {
  const doc = '(set :m [["x" 0 0 0] [0 1 0 0] [0 0 1 0] [0 0 0 1]])';
  assert.strictEqual(spanTextOf(doc, 'wrong_underlying'), '"x"');
});

test('a nested row failure spans the row', () => {
  const doc = '(set :m [[1 0 0 0] [0 1 0 0] [0 0 1 0] [0 0 0]])';
  assert.strictEqual(spanTextOf(doc, 'vector_length_mismatch'), '[0 0 0]');
});

test('a container-level vector failure stays on the container', () => {
  // `vector_length_mismatch` on the mat4 itself is not an element failure:
  // the fault is the arity, so the span is the whole vector.
  assert.strictEqual(spanTextOf('(set :m [[1 0 0 0]])', 'vector_length_mismatch'), '[[1 0 0 0]]');
});

test('the element wrap is spelled `element [N]: `, as in Zig', () => {
  // Only the index spelling is pinned against Zig. The rest of this
  // sentence is NOT byte-identical to `Validator.zig` and is not claimed to
  // be: the port composes the slot prefix inside each leaf's own message
  // closure, so the wrap lands in front of the prefix rather than after it,
  // the prefix names the *element* type rather than the outer slot's kind,
  // and there is no `, got <node>` tail. Messages are not corpus-compared,
  // so this is a standing divergence rather than a regression — closing it
  // means changing the `MatchFail` message protocol, which plan 18 did not.
  assert.strictEqual(
    messageOf('(set :v [1 "two" 3])', 'wrong_underlying'),
    'element [1]: form `set` keyword `:v` expects number',
  );
});

test('the wrap nests one segment per level, outer index first', () => {
  const doc = '(set :m [["x" 0 0 0] [0 1 0 0] [0 0 1 0] [0 0 0 1]])';
  assert.match(messageOf(doc, 'wrong_underlying'), /^element \[0\]: element \[0\]: /);
});
