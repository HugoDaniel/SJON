// Task 4 pins the container half of the reader: forms, vectors, their
// half-open UTF-8 byte spans, qualified heads, and the one greedy
// `:key value` pairing pass.
//
// Every expected span below was read out of the built `sjon.wasm`'s
// `sjon_node_table` (the same table Task 6 will project onto), and the
// pairing expectations follow `Parser.zig`'s frame rules: one pending-key
// slot per form, a keyword before another keyword or the frame close is a
// positional flag, and vectors/top level never grow kvpair nodes.
//
// Clean sources go through both entries: `readResult` for the tree and the
// empty diagnostic list, `read` for the same roots through the throwing
// entry. Invalid heads are inspected through `readResult` because the engine
// reports them with an `err` diagnostic, which `read` deliberately refuses.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  read,
  readResult,
  type FormNode,
  type KeywordNode,
  type Node,
  type NumberNode,
  type Span,
  type StringNode,
  type SymbolNode,
  type VectorNode,
} from '../src/index.ts';

function span(start: number, end: number): Span {
  return { start, end };
}

function numberNode(
  start: number,
  end: number,
  value: number,
  integer: bigint | null = null,
): NumberNode {
  return { tag: 'number', span: span(start, end), value, unit: null, integer };
}

function symbolNode(start: number, end: number, value: string): SymbolNode {
  return { tag: 'symbol', span: span(start, end), value };
}

function keywordNode(start: number, end: number, value: string): KeywordNode {
  return { tag: 'keyword', span: span(start, end), value };
}

function stringNode(start: number, end: number, value: string): StringNode {
  return { tag: 'string', span: span(start, end), value };
}

function vectorNode(start: number, end: number, elements: readonly Node[]): VectorNode {
  return { tag: 'vector', span: span(start, end), elements };
}

function formNode(
  start: number,
  end: number,
  head: string,
  headSpan: Span,
  children: readonly Node[],
  namespace: string | null = null,
): FormNode {
  return { tag: 'form', span: span(start, end), head, namespace, headSpan, children };
}

function kvpairNode(start: number, end: number, key: string, keySpan: Span, value: Node): Node {
  return { tag: 'kvpair', span: span(start, end), key, keySpan, value };
}

/** A clean source must produce exactly `expected` through both entries. */
function assertClean(source: string, expected: readonly Node[]): void {
  const result = readResult(source);
  assert.deepEqual(result.diagnostics, [], `${JSON.stringify(source)}: expected no diagnostics`);
  assert.deepEqual(result.roots, expected, `${JSON.stringify(source)}: readResult roots`);
  assert.deepEqual(read(source), expected, `${JSON.stringify(source)}: read roots`);
}

function onlyRoot(source: string): Node {
  const roots = read(source);
  assert.equal(roots.length, 1, `${JSON.stringify(source)}: expected one root`);
  const root = roots[0];
  assert.ok(root, `${JSON.stringify(source)}: missing root`);
  return root;
}

test('a form pins its delimiters, unqualified head, and headSpan', () => {
  assertClean('(scene)', [formNode(0, 7, 'scene', span(1, 6), [])]);
});

test('a vector pins its delimiters and element spans', () => {
  assertClean('[1 2 3]', [
    vectorNode(0, 7, [numberNode(1, 2, 1, 1n), numberNode(3, 4, 2, 2n), numberNode(5, 6, 3, 3n)]),
  ]);
});

test('(camera :ortho :zoom 2) is a positional flag plus zoom = 2', () => {
  assertClean('(camera :ortho :zoom 2)', [
    formNode(0, 23, 'camera', span(1, 7), [
      keywordNode(8, 14, 'ortho'),
      kvpairNode(15, 22, 'zoom', span(15, 20), numberNode(21, 22, 2, 2n)),
    ]),
  ]);
});

test('nested forms keep their own span and headSpan', () => {
  assertClean('(canvas (camera :ortho :zoom 2))', [
    formNode(0, 32, 'canvas', span(1, 7), [
      formNode(8, 31, 'camera', span(9, 15), [
        keywordNode(16, 22, 'ortho'),
        kvpairNode(23, 30, 'zoom', span(23, 28), numberNode(29, 30, 2, 2n)),
      ]),
    ]),
  ]);
});

test('children stay in source order, with each kvpair where its key appeared', () => {
  assertClean('(a 1 :k 2 3 :j 4 :k 5)', [
    formNode(0, 22, 'a', span(1, 2), [
      numberNode(3, 4, 1, 1n),
      kvpairNode(5, 9, 'k', span(5, 7), numberNode(8, 9, 2, 2n)),
      numberNode(10, 11, 3, 3n),
      kvpairNode(12, 16, 'j', span(12, 14), numberNode(15, 16, 4, 4n)),
      kvpairNode(17, 21, 'k', span(17, 19), numberNode(20, 21, 5, 5n)),
    ]),
  ]);
});

test('a keyword before the frame close is a positional flag', () => {
  assertClean('(a :k)', [formNode(0, 6, 'a', span(1, 2), [keywordNode(3, 5, 'k')])]);
});

test('a keyword-looking value never pairs: :k flushes before :v', () => {
  assertClean('(a :k :v)', [
    formNode(0, 9, 'a', span(1, 2), [keywordNode(3, 5, 'k'), keywordNode(6, 8, 'v')]),
  ]);
});

test('the next non-keyword value pairs with the surviving pending key', () => {
  assertClean('(a :k :v 1)', [
    formNode(0, 11, 'a', span(1, 2), [
      keywordNode(3, 5, 'k'),
      kvpairNode(6, 10, 'v', span(6, 8), numberNode(9, 10, 1, 1n)),
    ]),
  ]);
});

test('a kvpair value may be a vector or a form', () => {
  assertClean('(a :k [1 2])', [
    formNode(0, 12, 'a', span(1, 2), [
      kvpairNode(
        3,
        11,
        'k',
        span(3, 5),
        vectorNode(6, 11, [numberNode(7, 8, 1, 1n), numberNode(9, 10, 2, 2n)]),
      ),
    ]),
  ]);
  assertClean('(outer :inner (x :y 1))', [
    formNode(0, 23, 'outer', span(1, 6), [
      kvpairNode(
        7,
        22,
        'inner',
        span(7, 13),
        formNode(14, 22, 'x', span(15, 16), [
          kvpairNode(17, 21, 'y', span(17, 19), numberNode(20, 21, 1, 1n)),
        ]),
      ),
    ]),
  ]);
});

test('a vector never invents pairs: :k and :v stay positional keywords', () => {
  assertClean('[1 :foo "bar"]', [
    vectorNode(0, 14, [
      numberNode(1, 2, 1, 1n),
      keywordNode(3, 7, 'foo'),
      stringNode(8, 13, 'bar'),
    ]),
  ]);
  assertClean('[:k :v]', [vectorNode(0, 7, [keywordNode(1, 3, 'k'), keywordNode(4, 6, 'v')])]);
});

test('the top level never invents a kvpair: :k 1 is two roots', () => {
  const result = readResult(':k 1 2');
  assert.ok(
    result.roots.every((root) => root.tag !== 'kvpair'),
    'a root must never be a kvpair node',
  );
  assert.deepEqual(result.roots, [
    keywordNode(0, 2, 'k'),
    numberNode(3, 4, 1, 1n),
    numberNode(5, 6, 2, 2n),
  ]);
  assert.deepEqual(result.diagnostics, [
    {
      // Parser.zig's `emit` leaves `severity` at the Diagnostic default:
      // every parser-collected diagnostic is an `err`.
      code: 'unspecified',
      severity: 'err',
      message: 'keyword pair at top level (expected inside a form)',
      span: span(0, 2),
      path: [],
    },
  ]);
});

test('comments between a key and its value do not flush the pending key', () => {
  assertClean('(a ; note\n 1 :k ; gap\n 2)', [
    formNode(0, 25, 'a', span(1, 2), [
      numberNode(11, 12, 1, 1n),
      kvpairNode(13, 24, 'k', span(13, 15), numberNode(23, 24, 2, 2n)),
    ]),
  ]);
});

test('a qualified head splits once, at its first interior slash', () => {
  assertClean('(masagin/verb)', [formNode(0, 14, 'verb', span(1, 13), [], 'masagin')]);
  assertClean('(a/b/c)', [formNode(0, 7, 'b/c', span(1, 6), [], 'a')]);
  assertClean('(/head)', [formNode(0, 7, '/head', span(1, 6), [])]);
  assertClean('(ns/)', [formNode(0, 5, 'ns/', span(1, 4), [])]);
});

test('a reserved word is a legal head and keeps its spelling', () => {
  assertClean('(true 1)', [formNode(0, 8, 'true', span(1, 5), [numberNode(6, 7, 1, 1n)])]);
});

test('an invalid head diagnoses, keeps the head token as a child, and spans the real close', () => {
  const result = readResult('(1 2)');
  assert.deepEqual(result.roots, [
    formNode(0, 5, '', span(1, 1), [numberNode(1, 2, 1, 1n), numberNode(3, 4, 2, 2n)]),
  ]);
  assert.deepEqual(result.diagnostics, [
    {
      code: 'unspecified',
      severity: 'err',
      message: 'expected head symbol after `(`',
      span: span(1, 2),
      path: [],
    },
  ]);
});

test('an empty form diagnoses and still carries its delimiter span', () => {
  const result = readResult('()');
  assert.deepEqual(result.roots, [formNode(0, 2, '', span(1, 1), [])]);
  assert.deepEqual(result.diagnostics, [
    {
      code: 'unspecified',
      severity: 'err',
      message: 'empty form: expected head symbol after `(`',
      span: span(1, 2),
      path: [],
    },
  ]);
});

test("a keyword head diagnoses and becomes the synthetic form's positional child", () => {
  const result = readResult('(:k)');
  assert.deepEqual(result.roots, [formNode(0, 4, '', span(1, 1), [keywordNode(1, 3, 'k')])]);
  assert.deepEqual(result.diagnostics, [
    {
      code: 'unspecified',
      severity: 'err',
      message: 'expected head symbol after `(`',
      span: span(1, 3),
      path: [],
    },
  ]);
});

test('an invalid head inside a form carries the path of the slot it occupies', () => {
  const result = readResult('(a (1))');
  assert.deepEqual(result.roots, [
    formNode(0, 7, 'a', span(1, 2), [formNode(3, 6, '', span(4, 4), [numberNode(4, 5, 1, 1n)])]),
  ]);
  assert.deepEqual(result.diagnostics, [
    {
      code: 'unspecified',
      severity: 'err',
      message: 'expected head symbol after `(`',
      span: span(4, 5),
      path: ['a', '0'],
    },
  ]);
});

test('spans stay UTF-8 byte offsets after non-ASCII text', () => {
  assertClean('"héllo ☀️" (a)', [
    stringNode(0, 15, 'héllo ☀️'),
    formNode(16, 19, 'a', span(17, 18), []),
  ]);
  assertClean('"é" [1]', [stringNode(0, 4, 'é'), vectorNode(5, 8, [numberNode(6, 7, 1, 1n)])]);
  assertClean('(a "é")', [formNode(0, 8, 'a', span(1, 2), [stringNode(3, 7, 'é')])]);
});

test('symbols and keywords inside a frame are positionals with their own spans', () => {
  const root = onlyRoot('(a foo :bar)');
  assert.equal(root.tag, 'form');
  if (root.tag !== 'form') return;
  assert.deepEqual(root.children, [symbolNode(3, 6, 'foo'), keywordNode(7, 11, 'bar')]);
});
