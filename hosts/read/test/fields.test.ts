// Task 4 pins `fields` as a **view** over a form's existing children, never a
// second pairing pass:
//
//   * `pairs` are the children already tagged `kvpair`, in source order;
//   * `positionals` are everything else, including positional flags;
//   * duplicate keys survive in `pairs`, and `get` scans backwards so the
//     last source-order pair wins;
//   * a non-form argument is a programmer TypeError, not a diagnostic.
//
// The hand-built cases are the important half: a re-pairing implementation
// would turn a keyword child followed by a symbol child into a pair even
// though the parser never did, and these cases would then disagree with the
// tree they were handed.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  fields,
  read,
  type FormNode,
  type KeywordNode,
  type KvpairNode,
  type Node,
  type NumberNode,
  type Span,
  type SymbolNode,
  type VectorNode,
} from '../src/index.ts';

function span(start: number, end: number): Span {
  return { start, end };
}

function numberNode(start: number, end: number, value: number): NumberNode {
  return { tag: 'number', span: span(start, end), value, unit: null, integer: BigInt(value) };
}

function symbolNode(start: number, end: number, value: string): SymbolNode {
  return { tag: 'symbol', span: span(start, end), value };
}

function keywordNode(start: number, end: number, value: string): KeywordNode {
  return { tag: 'keyword', span: span(start, end), value };
}

function vectorNode(start: number, end: number, elements: readonly Node[]): VectorNode {
  return { tag: 'vector', span: span(start, end), elements };
}

function kvpairNode(keySpan: Span, key: string, value: Node): KvpairNode {
  return {
    tag: 'kvpair',
    span: span(keySpan.start, value.span.end),
    key,
    keySpan,
    value,
  };
}

function formNode(children: readonly Node[]): FormNode {
  return {
    tag: 'form',
    span: span(0, 1),
    head: 'a',
    namespace: null,
    headSpan: span(1, 2),
    children,
  };
}

function parsedForm(source: string): FormNode {
  const roots = read(source);
  assert.equal(roots.length, 1, `${JSON.stringify(source)}: expected one root`);
  const root = roots[0];
  assert.ok(root, `${JSON.stringify(source)}: missing root`);
  assert.equal(root.tag, 'form', `${JSON.stringify(source)}: expected a form root`);
  if (root.tag !== 'form') throw new Error('unreachable');
  return root;
}

test('a parsed form partitions pairs and positionals in source order', () => {
  const form = parsedForm('(a 1 :k 2 :flag :k 3)');
  const view = fields(form);

  assert.deepEqual(
    view.pairs.map((pair) => pair.key),
    ['k', 'k'],
  );
  assert.deepEqual(
    view.positionals.map((node) => node.tag),
    ['number', 'keyword'],
  );
  // The view filters the existing children; it does not copy or rebuild them.
  assert.equal(view.pairs[0], form.children[1]);
  assert.equal(view.pairs[1], form.children[3]);
  assert.equal(view.positionals[0], form.children[0]);
  assert.equal(view.positionals[1], form.children[2]);
});

test('last source-order pair wins and duplicates stay available', () => {
  const form = parsedForm('(a :k 1 :k 2)');
  const view = fields(form);

  assert.equal(view.pairs.length, 2);
  const firstPair = view.pairs[0];
  assert.ok(firstPair);
  assert.equal(firstPair.value.tag, 'number');
  if (firstPair.value.tag === 'number') assert.equal(firstPair.value.value, 1);

  const last = view.get('k');
  assert.ok(last);
  assert.equal(last.tag, 'number');
  if (last.tag === 'number') assert.equal(last.value, 2);
});

test('a flag is positional and is never returned by get', () => {
  const form = parsedForm('(a :ortho)');
  const view = fields(form);

  assert.deepEqual(view.pairs, []);
  assert.deepEqual(
    view.positionals.map((node) => (node.tag === 'keyword' ? node.value : node.tag)),
    ['ortho'],
  );
  assert.equal(view.get('ortho'), undefined);
  assert.equal(view.get(':ortho'), undefined);
});

test('get is exact and only matches pair keys, never positional keywords', () => {
  const flag = keywordNode(3, 5, 'k');
  const value = numberNode(6, 7, 1);
  const form = formNode([kvpairNode(span(0, 2), 'k', value), flag]);
  const view = fields(form);

  assert.equal(view.get('k'), value);
  assert.equal(view.get(':k'), undefined);
  assert.equal(view.get('K'), undefined);
  assert.equal(view.get('missing'), undefined);
});

test('a keyword child followed by a symbol child is not re-paired by the view', () => {
  const keyword = keywordNode(3, 5, 'k');
  const symbol = symbolNode(6, 7, 'v');
  const form = formNode([keyword, symbol]);
  const view = fields(form);

  assert.deepEqual(view.pairs, []);
  assert.equal(view.positionals.length, 2);
  assert.equal(view.positionals[0], keyword);
  assert.equal(view.positionals[1], symbol);
  assert.equal(view.get('k'), undefined);
});

test('last-wins follows pair order even when other children interleave', () => {
  const first = numberNode(0, 1, 1);
  const second = numberNode(2, 3, 2);
  const form = formNode([
    kvpairNode(span(0, 0), 'k', first),
    symbolNode(4, 5, 'x'),
    kvpairNode(span(6, 6), 'k', second),
  ]);
  const view = fields(form);

  assert.deepEqual(
    view.pairs.map((pair) => pair.value),
    [first, second],
  );
  assert.equal(view.get('k'), second);
  assert.equal(view.positionals.length, 1);
});

test('an empty form yields empty pairs, positionals, and a miss for every key', () => {
  const view = fields(formNode([]));
  assert.deepEqual(view.pairs, []);
  assert.deepEqual(view.positionals, []);
  assert.equal(view.get('k'), undefined);
});

test('fields rejects a non-form node with a TypeError', () => {
  const notForms: readonly unknown[] = [
    numberNode(0, 1, 1),
    symbolNode(0, 1, 'x'),
    keywordNode(0, 2, 'k'),
    vectorNode(0, 2, []),
    { tag: 'nil', span: span(0, 0) },
    kvpairNode(span(0, 2), 'k', numberNode(2, 3, 1)),
    null,
    undefined,
  ];

  for (const candidate of notForms) {
    assert.throws(
      () => fields(candidate as FormNode),
      (error: unknown) => error instanceof TypeError && /form/i.test(error.message),
    );
  }
});
