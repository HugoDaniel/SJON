// Curated expression sources for the engine oracle.
//
// `sjon_to_json` is given the core schema, so a form whose head names an
// expression function is collapsed to `{"$expr":[…]}` — or refused with
// `InvalidExprForm` when it carries kvpairs. Neither is a source-tree
// representation, so the value leg records the `expression` exclusion and the
// structural leg compares these forms as trees. The expected marks are the
// guard against that exclusion silently disappearing: if the engine stops
// collapsing one of these, the value leg reports a plain root instead and the
// curated count check fails.

import type { CuratedCase } from '../helpers/oracle.ts';

export const expressionCases: readonly CuratedCase[] = [
  {
    name: 'expression/${expr} a bare arithmetic form collapses',
    source: '(+ 1 2)',
    expected: ['expression'],
  },
  {
    name: 'expression/${expr} two roots keep the exclusion per root',
    source: '(+ 1 2) (* 3 4)',
    expected: ['expression', 'expression'],
  },
  {
    name: 'expression/${expr} a nested expression is still not source structure',
    source: '(f (+ 1 2))',
    expected: ['expression'],
  },
  {
    name: 'expression/${expr} a core let form collapses with its vector',
    source: '(let [r 0.5em] (vec3 r r r))',
    expected: ['expression'],
  },
  {
    name: 'expression/InvalidExprForm an expression with labels is refused',
    source: '(lerp :from 0 :to 1 :t 0.5)',
    expected: ['expression'],
  },
  {
    name: 'expression/InvalidExprForm a nested labelled expression is refused',
    source: '(f (lerp :from 0 :t 0.5))',
    expected: ['expression'],
  },
  {
    name: 'expression/root-scope a clean sibling root is still value-checked',
    source: '(lerp :from 0 :to 1 :t 0.5) (scene)',
    expected: ['expression', 'plain'],
  },
];
