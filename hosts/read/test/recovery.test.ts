// Task 5 pins structural recovery, diagnostic paths, and the depth stop.
//
// Every expectation below was measured against the built `sjon.wasm`'s
// `sjon_node_table` (structure, spans, code/severity) and against
// `Parser.zig`'s own path tests (`src/Parser.zig:2553+`) for the semantic
// path a diagnostic carries, which node-table JSON does not expose.
//
// The depth boundary is the engine's, not the plan's: `MAX_PARSE_DEPTH`
// counts the root frame, so 1,023 containers parse and the open of the
// 1,024th is diagnosed. `src/Parser.zig:2714` pins the same boundary on the
// engine side. The plan's "1024 accepted versus 1025 diagnosed" is off by
// one and is deliberately not encoded here.
//
// Recovery is collection over abort: every case returns a partial forest
// and its diagnostics instead of throwing. `read` still refuses that forest
// (see `read-error.test.ts`); this file inspects `readResult`.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  read,
  readResult,
  ReadError,
  type FormNode,
  type KeywordNode,
  type Node,
  type NumberNode,
  type ReadDiagnostic,
  type ReadResult,
  type Span,
  type SymbolNode,
  type VectorNode,
} from '../src/index.ts';
import { MAX_PARSE_DEPTH } from '../src/parser.ts';

function span(start: number, end: number): Span {
  return { start, end };
}

function numberNode(start: number, end: number, value: number): NumberNode {
  return { tag: 'number', span: span(start, end), value, unit: null, integer: BigInt(value) };
}

function keywordNode(start: number, end: number, value: string): KeywordNode {
  return { tag: 'keyword', span: span(start, end), value };
}

function symbolNode(start: number, end: number, value: string): SymbolNode {
  return { tag: 'symbol', span: span(start, end), value };
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
): FormNode {
  return { tag: 'form', span: span(start, end), head, namespace: null, headSpan, children };
}

function diagnosticAt(result: ReadResult, index: number): ReadDiagnostic {
  const found = result.diagnostics[index];
  assert.ok(found, `missing diagnostic at index ${index}`);
  return found;
}

function onlyRoot(result: ReadResult): Node {
  assert.equal(result.roots.length, 1, 'expected one recovered root');
  const root = result.roots[0];
  assert.ok(root, 'expected one recovered root');
  return root;
}

/** Container nesting depth of one node; leaves are depth 0. */
function depthOf(node: Node): number {
  switch (node.tag) {
    case 'form':
      return 1 + Math.max(0, ...node.children.map(depthOf));
    case 'vector':
      return 1 + Math.max(0, ...node.elements.map(depthOf));
    default:
      return 0;
  }
}

test('unclosed forms report innermost-first with paths and close at EOF', () => {
  const source = '(a (b (c';
  const result = readResult(source);

  assert.deepEqual(result.roots, [
    formNode(0, 8, 'a', span(1, 2), [
      formNode(3, 8, 'b', span(4, 5), [formNode(6, 8, 'c', span(7, 8), [])]),
    ]),
  ]);
  assert.deepEqual(
    result.diagnostics.map((diagnostic) => ({
      message: diagnostic.message,
      span: diagnostic.span,
      path: diagnostic.path,
    })),
    [
      { message: 'unclosed delimiter at end of input', span: span(8, 8), path: ['a', 'b', 'c'] },
      { message: 'unclosed delimiter at end of input', span: span(8, 8), path: ['a', 'b'] },
      { message: 'unclosed delimiter at end of input', span: span(8, 8), path: ['a'] },
    ],
  );
  assert.throws(() => read(source), ReadError);
});

test('an unclosed vector inside a form reports the vector slot then the form', () => {
  const source = '(a [1';
  const result = readResult(source);

  assert.deepEqual(result.roots, [
    formNode(0, 5, 'a', span(1, 2), [vectorNode(3, 5, [numberNode(4, 5, 1)])]),
  ]);
  assert.deepEqual(
    result.diagnostics.map((diagnostic) => ({
      message: diagnostic.message,
      span: diagnostic.span,
      path: diagnostic.path,
    })),
    [
      { message: 'unclosed delimiter at end of input', span: span(5, 5), path: ['a', '0'] },
      { message: 'unclosed delimiter at end of input', span: span(5, 5), path: ['a'] },
    ],
  );
});

test('a stray close at top level is skipped and every later root survives', () => {
  const source = ') 42 43';
  const result = readResult(source);

  assert.deepEqual(result.roots, [numberNode(2, 4, 42), numberNode(5, 7, 43)]);
  const diagnostic = diagnosticAt(result, 0);
  assert.equal(diagnostic.message, 'unexpected close delimiter at top level');
  assert.deepEqual(diagnostic.span, span(0, 1));
  assert.deepEqual(diagnostic.path, []);
  assert.equal(result.diagnostics.length, 1);
});

test('each stray close is one diagnostic and produces no node', () => {
  const result = readResult(')]');

  assert.deepEqual(result.roots, []);
  assert.deepEqual(
    result.diagnostics.map((diagnostic) => diagnostic.span),
    [span(0, 1), span(1, 2)],
  );
  assert.ok(
    result.diagnostics.every(
      (diagnostic) => diagnostic.message === 'unexpected close delimiter at top level',
    ),
  );
});

test('a mismatched close closes the open form and reports at that form', () => {
  const source = '(parent (a])';
  const result = readResult(source);

  assert.deepEqual(result.roots, [
    formNode(0, 12, 'parent', span(1, 7), [formNode(8, 11, 'a', span(9, 10), [])]),
  ]);
  const diagnostic = diagnosticAt(result, 0);
  assert.equal(diagnostic.message, 'mismatched close delimiter');
  assert.deepEqual(diagnostic.span, span(10, 11));
  assert.deepEqual(diagnostic.path, ['parent', 'a']);
  assert.equal(result.diagnostics.length, 1);
});

test('an invalid token diagnoses without attaching and parsing continues', () => {
  const first = readResult('(a , 1)');
  assert.deepEqual(first.roots, [formNode(0, 7, 'a', span(1, 2), [numberNode(5, 6, 1)])]);
  const comma = diagnosticAt(first, 0);
  assert.equal(comma.message, 'invalid token');
  assert.deepEqual(comma.span, span(3, 4));
  assert.deepEqual(comma.path, ['a', '0']);
  assert.equal(first.diagnostics.length, 1);

  const second = readResult('(a 1 , 2)');
  assert.deepEqual(second.roots, [
    formNode(0, 9, 'a', span(1, 2), [numberNode(3, 4, 1), numberNode(7, 8, 2)]),
  ]);
  const laterComma = diagnosticAt(second, 0);
  assert.deepEqual(laterComma.span, span(5, 6));
  assert.deepEqual(laterComma.path, ['a', '1']);
});

test('an unterminated string is one invalid token, then the form closes at EOF', () => {
  const source = '(a "unterminated';
  const result = readResult(source);

  assert.deepEqual(result.roots, [formNode(0, 16, 'a', span(1, 2), [])]);
  assert.deepEqual(
    result.diagnostics.map((diagnostic) => ({
      message: diagnostic.message,
      span: diagnostic.span,
      path: diagnostic.path,
    })),
    [
      { message: 'invalid token', span: span(3, 16), path: ['a', '0'] },
      { message: 'unclosed delimiter at end of input', span: span(16, 16), path: ['a'] },
    ],
  );
});

test('an unterminated block comment is one invalid token, then the form closes', () => {
  const source = '(a #| unterminated';
  const result = readResult(source);

  assert.deepEqual(result.roots, [formNode(0, 18, 'a', span(1, 2), [])]);
  assert.deepEqual(
    result.diagnostics.map((diagnostic) => ({
      message: diagnostic.message,
      span: diagnostic.span,
      path: diagnostic.path,
    })),
    [
      { message: 'invalid token', span: span(3, 18), path: ['a', '0'] },
      { message: 'unclosed delimiter at end of input', span: span(18, 18), path: ['a'] },
    ],
  );
});

test('a bare 0x prefix is skipped and the rest of the form still parses', () => {
  const result = readResult('(a 0x 1)');

  assert.deepEqual(result.roots, [formNode(0, 8, 'a', span(1, 2), [numberNode(6, 7, 1)])]);
  const diagnostic = diagnosticAt(result, 0);
  assert.equal(diagnostic.message, 'invalid token');
  assert.deepEqual(diagnostic.span, span(3, 5));
  assert.deepEqual(diagnostic.path, ['a', '0']);
  assert.equal(result.diagnostics.length, 1);
});

test('a pending key becomes a flag before an unclosed form is finalized', () => {
  const result = readResult('(a :k');

  assert.deepEqual(result.roots, [formNode(0, 5, 'a', span(1, 2), [keywordNode(3, 5, 'k')])]);
  const diagnostic = diagnosticAt(result, 0);
  assert.equal(diagnostic.message, 'unclosed delimiter at end of input');
  assert.deepEqual(diagnostic.span, span(5, 5));
  assert.deepEqual(diagnostic.path, ['a']);
});

test('a root-level pending pair unrolls after the open forms are closed', () => {
  const source = ':k (a';
  const result = readResult(source);

  assert.deepEqual(result.roots, [keywordNode(0, 2, 'k'), formNode(3, 5, 'a', span(4, 5), [])]);
  assert.deepEqual(
    result.diagnostics.map((diagnostic) => ({
      message: diagnostic.message,
      span: diagnostic.span,
      path: diagnostic.path,
    })),
    [
      { message: 'unclosed delimiter at end of input', span: span(5, 5), path: ['a'] },
      { message: 'keyword pair at top level (expected inside a form)', span: span(0, 2), path: [] },
    ],
  );
});

test('a top-level keyword pair is diagnosed and both roots survive', () => {
  const result = readResult(':k v');

  assert.deepEqual(result.roots, [keywordNode(0, 2, 'k'), symbolNode(3, 4, 'v')]);
  const diagnostic = diagnosticAt(result, 0);
  assert.equal(diagnostic.message, 'keyword pair at top level (expected inside a form)');
  assert.deepEqual(diagnostic.span, span(0, 2));
  assert.deepEqual(diagnostic.path, []);
});

test('diagnostic paths name kvpair keys, form heads, and vector slots', () => {
  // Each source and path is one of `Parser.zig`'s own attribution tests
  // (`src/Parser.zig:2586-2705`), which node-table JSON cannot compare.
  const kvpair = readResult('(parent :k "bad\\q")');
  assert.deepEqual(diagnosticAt(kvpair, 0).path, ['parent', 'k']);
  assert.deepEqual(diagnosticAt(kvpair, 0).span, span(11, 18));

  const vector = readResult('(parent ["ok" "bad\\q"])');
  assert.deepEqual(diagnosticAt(vector, 0).path, ['parent', '0', '1']);
  assert.deepEqual(diagnosticAt(vector, 0).span, span(14, 21));

  const nestedHead = readResult('(parent :slot (child :k "x\\q"))');
  assert.deepEqual(diagnosticAt(nestedHead, 0).path, ['parent', 'slot', 'child', 'k']);
  assert.deepEqual(diagnosticAt(nestedHead, 0).span, span(24, 29));

  // Two escapes in source order, naming the kvpair value and then the second
  // positional's first element (the `child` form is positional 0).
  const integration = readResult('(root (child :k "a\\q") ["b" "c\\q"])');
  assert.deepEqual(
    integration.diagnostics.map((diagnostic) => diagnostic.path),
    [
      ['root', 'child', 'k'],
      ['root', '1', '1'],
    ],
  );
  assert.deepEqual(
    integration.diagnostics.map((diagnostic) => diagnostic.span),
    [span(16, 21), span(28, 33)],
  );
});

test('depth counts the root frame: MAX_PARSE_DEPTH is 1024', () => {
  assert.equal(MAX_PARSE_DEPTH, 1024);
});

test('depth: 1,023 nested forms parse cleanly', () => {
  const depth = MAX_PARSE_DEPTH - 1;
  const source = '(x '.repeat(depth) + ')'.repeat(depth);
  const result = readResult(source);

  assert.deepEqual(result.diagnostics, []);
  assert.equal(depthOf(onlyRoot(result)), depth);
  assert.equal(read(source).length, 1);
});

test('depth: the 1,024th open parenthesis is diagnosed and the accepted frames close', () => {
  const depth = MAX_PARSE_DEPTH;
  const source = '(x '.repeat(depth);
  const result = readResult(source);

  assert.equal(result.roots.length, 1);
  assert.equal(depthOf(onlyRoot(result)), depth - 1);

  // One "nesting too deep" from the loop, then one "unclosed delimiter" for
  // every frame the stop left open (innermost first).
  assert.equal(result.diagnostics.length, depth);
  const overflow = diagnosticAt(result, 0);
  assert.equal(overflow.message, 'nesting too deep');
  assert.deepEqual(overflow.span, span(source.length - 3, source.length - 2));
  assert.equal(overflow.path.length, depth);
  assert.deepEqual(overflow.path.slice(-2), ['x', '0']);

  for (let index = 1; index < result.diagnostics.length; index += 1) {
    const diagnostic = diagnosticAt(result, index);
    assert.equal(diagnostic.message, 'unclosed delimiter at end of input');
    assert.deepEqual(diagnostic.span, span(source.length, source.length));
  }
  assert.equal(diagnosticAt(result, 1).path.length, depth - 1);
  assert.equal(diagnosticAt(result, result.diagnostics.length - 1).path.length, 1);

  assert.throws(() => read(source), ReadError);
});

test('depth: 1,023 nested vectors parse cleanly', () => {
  const depth = MAX_PARSE_DEPTH - 1;
  const source = '['.repeat(depth) + 'a' + ']'.repeat(depth);
  const result = readResult(source);

  assert.deepEqual(result.diagnostics, []);
  assert.equal(depthOf(onlyRoot(result)), depth);
});

test('depth: the 1,024th open bracket is diagnosed and the accepted frames close', () => {
  const depth = MAX_PARSE_DEPTH;
  const source = '['.repeat(depth) + 'a' + ']'.repeat(depth);
  const result = readResult(source);

  assert.equal(result.roots.length, 1);
  assert.equal(depthOf(onlyRoot(result)), depth - 1);
  assert.equal(result.diagnostics.length, depth);

  const overflow = diagnosticAt(result, 0);
  assert.equal(overflow.message, 'nesting too deep');
  assert.deepEqual(overflow.span, span(depth - 1, depth));
  // The first vector sits at the root, whose child step is empty, so every
  // path step is a positional "0" (the frames plus the in-progress slot).
  assert.equal(overflow.path.length, depth - 1);
  assert.ok(overflow.path.every((step) => step === '0'));

  for (let index = 1; index < result.diagnostics.length; index += 1) {
    const diagnostic = diagnosticAt(result, index);
    assert.equal(diagnostic.message, 'unclosed delimiter at end of input');
    assert.deepEqual(diagnostic.span, span(source.length, source.length));
  }
});
