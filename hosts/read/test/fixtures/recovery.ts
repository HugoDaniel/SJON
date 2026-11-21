// Curated recovery sources for the engine oracle.
//
// Every source here fires at least one parse diagnostic, so the value leg
// records the `parse-errors` exclusion and checks that `sjon_node_table`
// reported diagnostics too. The structural leg still runs: the partial forest,
// every span, and the `(code, severity, span)` sequence are compared against
// the engine. `expectedCodes` / `expectedPaths` pin the curated half that
// node-table JSON cannot expose — its rows carry no diagnostic paths.
//
// These are deliberately sparse: Task 5's `recovery.test.ts` owns exhaustive
// recovery and path parity. This fixture proves the oracle's third exclusion
// is exercised and that its reason is real, including diagnostics emitted by
// the atom layer (`date_invalid_*`, `time_invalid_*`, exact-integer overflow).

import type { CuratedCase } from '../helpers/oracle.ts';

export interface RecoveryCase extends CuratedCase {
  readonly expectedCodes: readonly string[];
  readonly expectedPaths: readonly (readonly string[])[];
}

export const recoveryCases: readonly RecoveryCase[] = [
  {
    name: 'recovery/unclosed-form an open frame closes at EOF innermost-first',
    source: '(a :k 1',
    expected: [],
    expectedCodes: ['unspecified'],
    expectedPaths: [['a']],
  },
  {
    name: 'recovery/unclosed-nested a vector and its form both close at EOF',
    source: '(a :k [1 2',
    expected: [],
    expectedCodes: ['unspecified', 'unspecified'],
    expectedPaths: [['a', 'k'], ['a']],
  },
  {
    name: 'recovery/stray-close a close with no frame is diagnosed and dropped',
    source: ')',
    expected: [],
    expectedCodes: ['unspecified'],
    expectedPaths: [[]],
  },
  {
    name: 'recovery/mismatched-close the wrong delimiter closes the form',
    source: '(a]',
    expected: [],
    expectedCodes: ['unspecified'],
    expectedPaths: [['a']],
  },
  {
    name: 'recovery/unterminated-string an open escaped string owns the tail',
    source: '"abc',
    expected: [],
    expectedCodes: ['unspecified'],
    expectedPaths: [[]],
  },
  {
    name: 'recovery/unterminated-block-comment the comment span reaches EOF',
    source: '#| unterminated',
    expected: [],
    expectedCodes: ['unspecified'],
    expectedPaths: [[]],
  },
  {
    name: 'recovery/top-level-pair a keyword pair at top level unrolls with an error',
    source: ':k 1',
    expected: [],
    expectedCodes: ['unspecified'],
    expectedPaths: [[]],
  },
  {
    name: 'recovery/date-invalid an impossible leap day is diagnosed and defaulted',
    source: '(a 1900-02-29)',
    expected: [],
    expectedCodes: ['date_invalid_day'],
    expectedPaths: [['a', '0']],
  },
  {
    name: 'recovery/date-month an out-of-range month is diagnosed and defaulted',
    source: '(a 2026-13-01)',
    expected: [],
    expectedCodes: ['date_invalid_month'],
    expectedPaths: [['a', '0']],
  },
  {
    name: 'recovery/time-invalid an out-of-range hour is diagnosed and defaulted',
    source: '24:00:00',
    expected: [],
    expectedCodes: ['time_invalid_hour'],
    expectedPaths: [[]],
  },
  {
    name: 'recovery/unknown-escape an unknown escape keeps its byte and is diagnosed',
    source: String.raw`(a "\q")`,
    expected: [],
    expectedCodes: ['unspecified'],
    expectedPaths: [['a', '0']],
  },
  {
    name: 'recovery/unicode-escape the stale backslash-u escape prose stays a literal',
    source: String.raw`"\u{1F600}"`,
    expected: [],
    expectedCodes: ['unspecified'],
    expectedPaths: [[]],
  },
  {
    name: 'recovery/integer-overflow an integer past u64 falls back to f64',
    source: '18446744073709551616',
    expected: [],
    expectedCodes: ['number_overflow_exact_integer'],
    expectedPaths: [[]],
  },
  {
    name: 'recovery/invalid-hex a bare 0x prefix is diagnosed at the prefix',
    source: '0x',
    expected: [],
    expectedCodes: ['unspecified'],
    expectedPaths: [[]],
  },
  {
    name: 'recovery/comma a comma is not whitespace',
    source: '(a , 1)',
    expected: [],
    expectedCodes: ['unspecified'],
    expectedPaths: [['a', '0']],
  },
  {
    name: 'recovery/stray-hash a lone # is invalid, not a comment',
    source: '#x',
    expected: [],
    expectedCodes: ['unspecified'],
    expectedPaths: [[]],
  },
];
