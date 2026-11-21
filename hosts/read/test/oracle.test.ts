// Task 6: the engine oracle and the curated parity corpus.
//
// Two legs, both driven through the built `sjon.wasm` (never its Zig source):
//
//   1. structure + spans: `sjon_node_table` rows vs `readResult` projected
//      into the same pre-order table, plus the `(code, severity, span)`
//      diagnostic sequence. Kvpairs contribute no row; their value carries
//      `seg = key` and `key_span`, and positional steps skip kvpairs.
//   2. values: each clean root's own UTF-8 bytes are sliced out and handed
//      to `sjon_to_json` as a single-root document, then compared with a
//      canonical projection of that reader root. Never a multi-root call.
//
// Only three representation losses are permitted, and each one is counted and
// required to keep its reason:
//
//   * `expression`     — the core schema collapses expression forms to
//                        `$expr` (or refuses a labelled one with
//                        `InvalidExprForm`); not source structure.
//   * `duplicate-key`  — a JSON object keeps one value per key.
//   * `parse-errors`   — the value bridge needs a clean tree; structure and
//                        diagnostics still run for these sources.
//
// The harness must fail loudly if the artifact is missing or stale-looking;
// `loadOracle` throws rather than skipping. It must also be able to fail on a
// one-byte reader divergence: the temporary form-span mutation proof in the
// task report was run against this file.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { readResult, type Node } from '../src/index.ts';
import { duplicateCases } from './fixtures/duplicates.ts';
import { expressionCases } from './fixtures/expressions.ts';
import { recoveryCases } from './fixtures/recovery.ts';
import {
  type CuratedCase,
  discoverCorpusCases,
  loadOracle,
  type RootExclusion,
  wasmPath,
} from './helpers/oracle.ts';
import {
  collectExpressionHeads,
  collectFormHeads,
  containsExpressionCollapse,
  countDuplicateKeyCollisions,
  engineDiagnostics,
  engineRows,
  formsWithKvpairs,
  jsonEqual,
  multisetContains,
  projectValue,
  readerDiagnostics,
  readerRows,
  renderJson,
} from './helpers/project.ts';

interface Case {
  readonly name: string;
  readonly source: string;
}

interface ExclusionCounts {
  expression: number;
  'duplicate-key': number;
  'parse-errors': number;
}

/** The brief's named curated requirements, beyond the three fixture files. */
const generalCases: readonly CuratedCase[] = [
  {
    name: 'general/empty the empty document has no roots and no rows',
    source: '',
    expected: [],
  },
  {
    name: 'general/greedy-pairing :ortho is a flag and :zoom pairs with 2',
    source: '(camera :ortho :zoom 2)',
    expected: ['plain'],
  },
  {
    name: 'general/non-ascii a multi-byte string before a node keeps byte spans',
    source: '"héllo ☀️" (a)',
    expected: ['plain', 'plain'],
  },
  {
    name: 'general/bom a leading BOM offsets every later byte span',
    source: '\uFEFF(a)',
    expected: ['plain'],
  },
  {
    name: 'general/raw-string a raw string is one string node',
    source: '(a """x""" "y")',
    expected: ['plain'],
  },
  {
    name: 'general/raw-multiline a raw string may contain a newline',
    source: '(label """multi\nline raw""")',
    expected: ['plain'],
  },
  {
    name: 'general/block-comment a non-nested block comment ends at the first close',
    source: '#| block #| not nested |# (a) (b)',
    expected: ['plain', 'plain'],
  },
  {
    name: 'general/block-comment-inside a block comment is trivia between children',
    source: '(a #| c |# 1)',
    expected: ['plain'],
  },
  {
    name: 'general/units every unit and exponent spelling keeps its value',
    source: '(a 4b 90deg 50% 250ms 1.5e2hz 2d-array 5ms-per-frame 1em 1e9 1.5e-10)',
    expected: ['plain'],
  },
  {
    name: 'general/hex hex stays exact and never grows a unit',
    source: '(a 0xFF 0Xff 0xdeadBEEF 0xFFFF_FFFF -0x10 0xFFms)',
    expected: ['plain'],
  },
  {
    name: 'general/exact-integers i64 and u64 boundaries are bit-faithful in JSON',
    source: '(a 9223372036854775807 9223372036854775808 18446744073709551615 -9223372036854775808)',
    expected: ['plain'],
  },
  {
    name: 'general/dates canonical date tags survive the JSON bridge',
    source: '(a 0001-01-01 9999-12-31)',
    expected: ['plain'],
  },
  {
    name: 'general/times canonical time tags shorten a zero fraction',
    source: '00:00:00 23:59:59.999 12:34:56.000',
    expected: ['plain', 'plain', 'plain'],
  },
  {
    name: 'general/atoms booleans nil keywords and symbols keep their tags',
    source: '(a true false nil :kw sym)',
    expected: ['plain'],
  },
  {
    name: 'general/escaped-string every implemented escape decodes to its byte value',
    source: '(a "\\n\\t\\r\\"\\\\\\0")',
    expected: ['plain'],
  },
  {
    name: 'general/containers vectors pair by index and forms nest',
    source: '(a :k [1 2] :j (b 3))',
    expected: ['plain'],
  },
  {
    name: 'general/top-level-keyword a keyword root carries no row-level pair',
    source: ':true',
    expected: ['plain'],
  },
  {
    name: 'general/sigil-symbols $ and @ stay symbol bytes',
    source: '$foo @bar',
    expected: ['plain', 'plain'],
  },
];

const curatedCases: readonly CuratedCase[] = [
  ...generalCases,
  ...expressionCases,
  ...duplicateCases,
];

const corpusCases = discoverCorpusCases();
const allCases: readonly Case[] = [...curatedCases, ...recoveryCases, ...corpusCases];

const oracle = await loadOracle();
const encoder = new TextEncoder();
const decoder = new TextDecoder();

let observedExclusions: ExclusionCounts | undefined;
let observedCuratedExclusions: ExclusionCounts | undefined;

test('the oracle discovers every curated family and every conformance .sjon fixture', (t) => {
  t.diagnostic(`oracle artifact: ${wasmPath}`);
  t.diagnostic(
    `discovered ${allCases.length} cases: ${curatedCases.length} curated, ` +
      `${recoveryCases.length} recovery, ${corpusCases.length} corpus`,
  );

  assert.ok(expressionCases.length > 0, 'no curated expression fixtures');
  assert.ok(duplicateCases.length > 0, 'no curated duplicate-key fixtures');
  assert.ok(recoveryCases.length > 0, 'no curated recovery fixtures');
  assert.ok(corpusCases.length > 0, 'no conformance .sjon fixtures discovered');

  // The brief names these families explicitly; a later edit must not drop one
  // and leave the exclusion counts propped up by corpus cases alone.
  assert.ok(
    expressionCases.some((item) => item.source === '(+ 1 2)'),
    'the curated $expr case `(+ 1 2)` is missing',
  );
  assert.ok(
    duplicateCases.some((item) => item.source === '(a :k 1 :k 2)'),
    'the curated duplicate-key case is missing',
  );
  assert.ok(
    generalCases.some((item) => item.source.includes('héllo ☀️')),
    'the curated non-ASCII span case is missing',
  );
  assert.ok(
    generalCases.some((item) => item.source.includes('"""')),
    'the curated raw-string case is missing',
  );
  assert.ok(
    generalCases.some((item) => item.source.includes('#|')),
    'the curated block-comment case is missing',
  );
});

test('structure, spans, and diagnostic sequences agree with sjon_node_table', (t) => {
  const failures: string[] = [];
  let rowsCompared = 0;

  for (const item of allCases) {
    const bytes = encoder.encode(item.source);
    const table = oracle.nodeTable(bytes);
    const result = readResult(item.source);
    const expectedRows = engineRows(table);
    const actualRows = readerRows(result.roots);
    rowsCompared += expectedRows.length;

    if (expectedRows.length !== actualRows.length) {
      failures.push(
        `${item.name}: ${actualRows.length} reader rows, ${expectedRows.length} engine rows`,
      );
    }
    const shared = Math.min(expectedRows.length, actualRows.length);
    for (let index = 0; index < shared; index += 1) {
      const expected = expectedRows[index];
      const actual = actualRows[index];
      if (expected === undefined || actual === undefined) continue;
      try {
        assert.deepStrictEqual(actual, expected);
      } catch (error) {
        failures.push(`${item.name}: row ${index}\n${indent(assertionMessage(error))}`);
      }
    }

    try {
      assert.deepStrictEqual(readerDiagnostics(result.diagnostics), engineDiagnostics(table));
    } catch (error) {
      failures.push(`${item.name}: diagnostic sequence\n${indent(assertionMessage(error))}`);
    }
  }

  t.diagnostic(`structure: ${allCases.length} cases, ${rowsCompared} rows compared`);
  assert.equal(failures.length, 0, failureReport(failures));
});

test('per-root values and tags agree with sjon_to_json', (t) => {
  const failures: string[] = [];
  const exclusions: ExclusionCounts = {
    expression: 0,
    'duplicate-key': 0,
    'parse-errors': 0,
  };
  const curatedExpected = new Map<string, readonly RootExclusion[]>();
  for (const item of curatedCases) curatedExpected.set(item.name, item.expected);
  const curatedObserved = new Map<string, RootExclusion[]>();

  let rootsCompared = 0;
  let rootsExcluded = 0;
  let collapsedExpressions = 0;
  let unrepresentableExpressions = 0;

  for (const item of allCases) {
    const bytes = encoder.encode(item.source);
    const result = readResult(item.source);

    if (result.diagnostics.length > 0) {
      exclusions['parse-errors'] += 1;
      if (curatedExpected.has(item.name)) {
        failures.push(
          `${item.name}: curated clean case produced parse diagnostics; value leg was excluded`,
        );
      }
      const table = oracle.nodeTable(bytes);
      if (table.diagnostics.length === 0) {
        failures.push(
          `${item.name}: parse-errors exclusion fired but sjon_node_table reported none`,
        );
      }
      continue;
    }

    const expectedMarks = curatedExpected.get(item.name);
    const marks: RootExclusion[] | null = expectedMarks === undefined ? null : [];

    for (let rootIndex = 0; rootIndex < result.roots.length; rootIndex += 1) {
      const root = result.roots[rootIndex];
      if (root === undefined) continue;
      const start = root.span.start;
      const end = root.span.end;
      if (start < 0 || end > bytes.length || start >= end) {
        failures.push(
          `${item.name}: root ${rootIndex} has an out-of-bounds/empty span [${start},${end})`,
        );
        continue;
      }

      // One root's own bytes, one call: never a multi-root document passed off
      // as a per-root check.
      const slice = bytes.subarray(start, end);
      const outcome = oracle.toJson(slice);
      let mark: RootExclusion;

      if (!outcome.ok) {
        if (outcome.error === 'InvalidExprForm' && hasLabelledExpression(root)) {
          mark = 'expression';
          unrepresentableExpressions += 1;
        } else {
          failures.push(
            `${item.name}: root ${rootIndex} sjon_to_json failed: ${outcome.error}\n` +
              `  slice ${JSON.stringify(decoder.decode(slice))}`,
          );
          continue;
        }
      } else {
        const engine = outcome.value;
        if (containsExpressionCollapse(engine)) {
          mark = 'expression';
          collapsedExpressions += 1;
          const requiredHeads = collectExpressionHeads(engine);
          if (!multisetContains(collectFormHeads(root), requiredHeads)) {
            failures.push(
              `${item.name}: root ${rootIndex} expression reason lost: ` +
                `$expr heads ${JSON.stringify(requiredHeads)} have no matching reader form`,
            );
          }
        } else if (countDuplicateKeyCollisions(root) > 0) {
          mark = 'duplicate-key';
          // Reason check, not a skip: the engine's object must be exactly this
          // root's last-wins projection, so the lost pairs are the only loss.
          const projected = projectValue(root);
          if (!jsonEqual(projected, engine)) {
            failures.push(
              `${item.name}: root ${rootIndex} duplicate-key reason check failed\n` +
                `  slice ${JSON.stringify(decoder.decode(slice))}\n` +
                `  engine ${renderJson(engine)}\n` +
                `  reader ${renderJson(projected)}`,
            );
          }
        } else {
          mark = 'plain';
          rootsCompared += 1;
          const projected = projectValue(root);
          if (!jsonEqual(projected, engine)) {
            failures.push(
              `${item.name}: root ${rootIndex} value mismatch\n` +
                `  slice ${JSON.stringify(decoder.decode(slice))}\n` +
                `  engine ${renderJson(engine)}\n` +
                `  reader ${renderJson(projected)}`,
            );
          }
        }
      }

      if (mark !== 'plain') {
        exclusions[mark] += 1;
        rootsExcluded += 1;
      }
      if (marks !== null) marks.push(mark);
    }

    if (expectedMarks !== undefined && marks !== null) {
      curatedObserved.set(item.name, marks);
      try {
        assert.deepStrictEqual(marks, expectedMarks);
      } catch (error) {
        failures.push(`${item.name}: curated root exclusions\n${indent(assertionMessage(error))}`);
      }
    }
  }

  const curatedCounts: ExclusionCounts = {
    expression: 0,
    'duplicate-key': 0,
    'parse-errors': 0,
  };
  for (const marks of curatedObserved.values()) {
    for (const mark of marks) {
      if (mark !== 'plain') curatedCounts[mark] += 1;
    }
  }
  for (const item of recoveryCases) {
    // Every recovery fixture must actually take the parse-errors path; a
    // recovered source that silently became clean would otherwise leave the
    // exclusion resting on corpus cases alone.
    if (readResult(item.source).diagnostics.length > 0) curatedCounts['parse-errors'] += 1;
  }

  observedExclusions = exclusions;
  observedCuratedExclusions = curatedCounts;

  t.diagnostic(
    `values: ${rootsCompared} roots compared, ${rootsExcluded} roots excluded ` +
      `(${collapsedExpressions} collapsed $expr, ${unrepresentableExpressions} InvalidExprForm)`,
  );
  t.diagnostic(
    `exclusions: expression=${exclusions.expression} ` +
      `duplicate-key=${exclusions['duplicate-key']} parse-errors=${exclusions['parse-errors']}; ` +
      `curated expression=${curatedCounts.expression} ` +
      `duplicate-key=${curatedCounts['duplicate-key']} ` +
      `parse-errors=${curatedCounts['parse-errors']}`,
  );
  assert.equal(failures.length, 0, failureReport(failures));
});

test('the three named exclusions are exercised and keep their reason', (t) => {
  assert.ok(observedExclusions !== undefined, 'the value leg did not finish');
  assert.ok(observedCuratedExclusions !== undefined, 'the value leg did not finish');

  assert.ok(corpusCases.length > 0, 'the corpus discovered no .sjon fixtures');
  assert.ok(
    observedExclusions.expression > 0,
    'expression exclusion count is zero — the $expr collapse stopped exhibiting its reason',
  );
  assert.ok(
    observedExclusions['duplicate-key'] > 0,
    'duplicate-key exclusion count is zero — no duplicate fixture loses a key',
  );
  assert.ok(
    observedExclusions['parse-errors'] > 0,
    'parse-errors exclusion count is zero — no source has a parse diagnostic',
  );
  assert.ok(
    observedCuratedExclusions.expression > 0,
    'curated expression exclusion count is zero — add or restore a curated $expr fixture',
  );
  assert.ok(
    observedCuratedExclusions['duplicate-key'] > 0,
    'curated duplicate-key exclusion count is zero — add or restore a duplicate fixture',
  );
  assert.equal(
    observedCuratedExclusions['parse-errors'],
    recoveryCases.length,
    'not every curated recovery fixture took the parse-errors value-leg exclusion',
  );

  t.diagnostic(
    `named exclusions: expression=${observedExclusions.expression} ` +
      `duplicate-key=${observedExclusions['duplicate-key']} ` +
      `parse-errors=${observedExclusions['parse-errors']}; ` +
      `curated expression=${observedCuratedExclusions.expression} ` +
      `duplicate-key=${observedCuratedExclusions['duplicate-key']} ` +
      `parse-errors=${observedCuratedExclusions['parse-errors']}`,
  );
});

test('curated recovery diagnostics keep their codes and paths', () => {
  for (const item of recoveryCases) {
    assert.equal(
      item.expectedCodes.length,
      item.expectedPaths.length,
      `${item.name}: fixture code/path lengths disagree`,
    );
    const result = readResult(item.source);
    assert.ok(result.diagnostics.length > 0, `${item.name}: expected at least one diagnostic`);
    assert.deepEqual(
      result.diagnostics.map((diagnostic) => diagnostic.code),
      item.expectedCodes,
      `${item.name}: diagnostic codes`,
    );
    assert.deepEqual(
      result.diagnostics.map((diagnostic) => diagnostic.path),
      item.expectedPaths,
      `${item.name}: diagnostic paths`,
    );
  }
});

/** True when `sjon_to_json`'s `InvalidExprForm` reason still exists. */
function hasLabelledExpression(root: Node): boolean {
  return formsWithKvpairs(root).some((form) => oracle.isExpressionHead(form.head, form.namespace));
}

function indent(message: string): string {
  return message
    .split('\n')
    .map((line) => `    ${line}`)
    .join('\n');
}

function assertionMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function failureReport(failures: readonly string[]): string {
  const limit = 20;
  const shown = failures.slice(0, limit).join('\n\n');
  const remaining = failures.length - limit;
  const tail = remaining > 0 ? `\n\n… and ${remaining} more` : '';
  return `${failures.length} oracle failure(s):\n\n${shown}${tail}`;
}
