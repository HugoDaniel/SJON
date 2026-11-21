// Form.skeleton — a backend-free starter document. Every declared key is
// emitted in declaration order: a declared default is deep-cloned into the
// document, every other key (required or optional) is the held symbol. The
// emitted text is ordinary SJON; the caller opts into `heldSymbol` on their
// validation run, and without that option the holes are ordinary symbols that
// report against their slots.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import * as s from '../src/builder.ts';
import * as v from '../src/value-ctor.ts';

// The measured `studio/starter` form: required `name`, defaulted `count`,
// optional `enabled` (no default, so it is a hole like the required key).
const Starter = s.form(
  'starter',
  {
    name: s.string(),
    count: s.number().default(2),
    enabled: s.boolean().optional(),
  },
  'studio',
);

test('skeleton emits the measured studio/starter starter byte for byte', () => {
  assert.equal(Starter.skeleton(), '(studio/starter :name _ :count 2 :enabled _)');
});

test('skeleton takes a custom hole spelling', () => {
  assert.equal(Starter.skeleton('hole'), '(studio/starter :name hole :count 2 :enabled hole)');
});

test('an invalid hole spelling throws through v.sym, not a bespoke error', () => {
  let ctorMessage: string | undefined;
  try {
    v.sym('2bad');
  } catch (err) {
    ctorMessage = (err as Error).message;
  }
  assert.ok(ctorMessage !== undefined, 'v.sym must reject a digit-leading spelling');
  assert.throws(
    () => Starter.skeleton('2bad'),
    (err: Error) => err.message === ctorMessage,
    'the skeleton must surface the value constructor’s own guard text',
  );
});

test('a vector default is deep-cloned, so a mutated document cannot touch the def', () => {
  const Grid = s.form('grid', { origin: s.vector(s.number(), 2).default([0, 0]) }, 'studio');
  // `create` is the mutable document path; the skeleton reads the same def and
  // must keep emitting the declared default after a caller mutates a document.
  const document = Grid.create({}) as unknown as { origin: number[] };
  document.origin[0] = 99;
  assert.deepEqual(Grid._def.keys[0]!.def.default, [0, 0]);
  assert.equal(Grid.skeleton(), '(studio/grid :origin [0 0])');
  assert.equal(Grid.skeleton(), '(studio/grid :origin [0 0])');
});

test('a positional form emits no fabricated $children', () => {
  const Lines = s.form('lines', { title: s.string() }, { ns: 'studio', positional: s.string() });
  assert.equal(Lines.skeleton(), '(studio/lines :title _)');

  const AnyLines = s.form('any-lines', { title: s.string() }, { ns: 'studio', positional: 'any' });
  assert.equal(AnyLines.skeleton(), '(studio/any-lines :title _)');
});
