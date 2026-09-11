// The bootstrap parser's refusal contract: a successful parse preserves
// the structure and values its consumers rely on, and recognised syntax
// it cannot interpret is an explicit error rather than a different tree.
//
// Both halves matter. The refusals are half; the near-misses are the
// other half, because a whole-file substring check for `"""` or `#|`
// would reject legitimate content and is exactly what these guard
// against.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  CONFORMANCE_DIALECT,
  parseNode,
  RESOLVER_DIALECT,
  skipTrivia,
} from '../sjonSubsetParser.ts';
import type { Dialect, ParsedNode } from '../sjonSubsetParser.ts';

const parse = (src: string, d: Dialect = RESOLVER_DIALECT): ParsedNode =>
  parseNode({ src, i: 0 }, d);

// -- Refusals ---------------------------------------------------------------

test('a raw string is refused, not read as three strings', () => {
  assert.throws(() => parse('(plugin :name """shapes""")'), /raw strings/);
});

test('an empty raw string is refused too', () => {
  // `""""""` is one empty raw string to the substrate lexer, so reading
  // it as three empty ordinary ones is the same class of misread.
  assert.throws(() => parse('(a """""")'), /raw strings/);
});

test('a block comment is refused, not parsed as data', () => {
  const src = '(project\n  #| :plugins ["disabled.sjon"] |#\n  :plugins ["active.sjon"])';
  assert.throws(() => parse(src), /block comments/);
});

test('both refusals fire in the conformance dialect too', () => {
  assert.throws(() => parse('(a """x""")', CONFORMANCE_DIALECT), /raw strings/);
  assert.throws(() => parse('(a #| c |# 1)', CONFORMANCE_DIALECT), /block comments/);
});

test('the refusal names the parser, so a reader knows which one refused', () => {
  assert.throws(() => parse('(a """x""")'), /bootstrap parser/);
});

test('skipTrivia refuses a leading block comment', () => {
  assert.throws(() => skipTrivia({ src: '#| head |# (a)', i: 0 }), /block comments/);
});

test('a block comment in the head position is refused, not read as a head', () => {
  // `parseForm` reads its head with `readSymbol`, which never reaches
  // `parseNode` — so the check has to live in `skipTrivia` to catch this.
  assert.throws(() => parse('(#| c |# a)'), /block comments/);
});

// -- Near-misses: these must still parse ------------------------------------

test('an empty string is still an empty string', () => {
  assert.deepEqual(parse('(a "" "b")'), {
    tag: 'form',
    head: 'a',
    children: [
      { tag: 'string', value: '' },
      { tag: 'string', value: 'b' },
    ],
  });
});

test('two adjacent empty strings are not a raw string', () => {
  // `"" ""` has a space between the pairs, so no token start sees three
  // quotes in a row.
  assert.equal((parse('(a "" "")') as { children: unknown[] }).children.length, 2);
});

test('`#` and `|` inside a symbol are symbol bytes, as they are in Lexer.zig', () => {
  assert.deepEqual(parse('(a b#c foo#|bar)'), {
    tag: 'form',
    head: 'a',
    children: [
      { tag: 'symbol', value: 'b#c' },
      { tag: 'symbol', value: 'foo#|bar' },
    ],
  });
});

test('`#|` and `"""` inside a string are content, not openers', () => {
  assert.deepEqual(parse('(a "#| not a comment |#" "not \\"\\"\\" raw")'), {
    tag: 'form',
    head: 'a',
    children: [
      { tag: 'string', value: '#| not a comment |#' },
      { tag: 'string', value: 'not """ raw' },
    ],
  });
});

test('`#|` inside a line comment is content, not an opener', () => {
  assert.deepEqual(parse('(a ; #| not a comment """ either\n  1)'), {
    tag: 'form',
    head: 'a',
    children: [{ tag: 'symbol', value: '1' }],
  });
});

// -- What the consumers would have acted on ---------------------------------

test('a manifest key no longer changes value under a raw string', () => {
  // `(plugin :name """shapes""")` used to yield `:name = ""` plus two
  // stray positional strings — a manifest key silently reading as
  // something the author did not write.
  assert.throws(() => parse('(plugin :name """shapes""" :version "1.0.0")'), /raw strings/);
});

test('disabled project config no longer reaches the resolver', () => {
  // The resolver indexes *every* `:plugins` kvpair it finds and does not
  // stop at the first, so the commented-out entry was indexed alongside
  // the live one: text the author disabled became configuration.
  const src = '(project\n  #| :plugins ["disabled.sjon"] |#\n  :plugins ["active.sjon"])';
  assert.throws(() => parse(src), /block comments/);
});
