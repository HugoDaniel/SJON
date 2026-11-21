// Curated duplicate-key sources for the engine oracle.
//
// A JSON object has one slot per key, so `sjon_to_json` keeps only the last
// value of a repeated pair. The reader preserves every pair in source order
// (`fields().pairs`), and the structural leg pins that order and count. The
// value leg records the `duplicate-key` exclusion and checks that the engine
// JSON is exactly this projection with last-wins collapsed — proving the lost
// pair is the only difference, never a blanket skip.
//
// `(camera :ortho :zoom 2)` is a plain root on purpose: greedy pairing is not
// a duplicate, and the value leg must compare it normally (`:ortho` is a
// positional flag, `zoom` is `2`).

import type { CuratedCase } from '../helpers/oracle.ts';

export const duplicateCases: readonly CuratedCase[] = [
  {
    name: 'duplicates/last-wins a repeated key loses its first value in JSON',
    source: '(a :k 1 :k 2)',
    expected: ['duplicate-key'],
  },
  {
    name: 'duplicates/order a repeated key among other keys keeps source structure',
    source: '(a :b 1 :a 2 :b 3)',
    expected: ['duplicate-key'],
  },
  {
    name: 'duplicates/same-value identical duplicates are still two pairs',
    source: '(a :k 1 :k 1)',
    expected: ['duplicate-key'],
  },
  {
    name: 'duplicates/nested a duplicate inside a nested form still excludes its root',
    source: '(outer (inner :k 1 :k 2))',
    expected: ['duplicate-key'],
  },
  {
    name: 'duplicates/mixed-vector a duplicate beside a vector',
    source: '(a :k [1 :x 2] :j (b :y 3 :y 4))',
    expected: ['duplicate-key'],
  },
  {
    name: 'duplicates/per-root one duplicate root does not exclude a clean sibling',
    source: '(duplicate :k 1 :k 2) (plain :k 3)',
    expected: ['duplicate-key', 'plain'],
  },
  {
    name: 'duplicates/not-a-duplicate greedy keyword pairing stays plain',
    source: '(camera :ortho :zoom 2)',
    expected: ['plain'],
  },
];
