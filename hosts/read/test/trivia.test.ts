// Task 2 red/green gate for source encoding and lexical trivia.
//
// The fixture table is the engine's token stream: every span is a UTF-8 byte
// offset. These cases pin BOM handling, both comment forms (block comments
// close at the first `|#`), NUL outside strings, comma rejection, and the
// distinction between a `#` that starts a comment and one inside a body.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { Lexer, type Token } from '../src/lexer.ts';
import { decodeRange, encodeSource } from '../src/source.ts';
import { type LexicalCase, triviaCases } from './fixtures/lexical.ts';

interface Lexed {
  readonly bytes: Uint8Array;
  readonly tokens: readonly Token[];
}

function lex(source: string): Lexed {
  const bytes = encodeSource(source);
  const lexer = new Lexer(bytes);
  const tokens: Token[] = [];
  const guard = bytes.length * 2 + 16;
  for (let i = 0; i < guard; i += 1) {
    const token = lexer.next();
    tokens.push(token);
    if (token.tag === 'eof') return { bytes, tokens };
  }
  assert.fail(`lexer did not reach eof for ${JSON.stringify(source)}`);
}

function assertLexes(fixture: LexicalCase): void {
  const { bytes, tokens } = lex(fixture.source);
  assert.equal(
    tokens.length,
    fixture.tokens.length + 1,
    `${fixture.name}: expected ${fixture.tokens.length} tokens before eof`,
  );

  const eof = tokens[tokens.length - 1];
  assert.ok(eof, `${fixture.name}: missing eof token`);
  assert.deepEqual(
    { tag: eof.tag, start: eof.start, end: eof.end },
    { tag: 'eof', start: bytes.length, end: bytes.length },
    `${fixture.name}: eof must sit at the byte length`,
  );

  fixture.tokens.forEach((expected, index) => {
    const actual = tokens[index];
    assert.ok(actual, `${fixture.name}: missing token ${index}`);
    assert.deepEqual(
      { tag: actual.tag, start: actual.start, end: actual.end },
      { tag: expected.tag, start: expected.start, end: expected.end },
      `${fixture.name}: token ${index}`,
    );
    assert.ok(
      actual.end >= actual.start && actual.end <= bytes.length,
      `${fixture.name}: token ${index} has an out-of-range span`,
    );
    if (expected.text !== undefined) {
      assert.equal(
        decodeRange(bytes, actual.start, actual.end),
        expected.text,
        `${fixture.name}: token ${index} lexeme`,
      );
    }
  });
}

test('encodeSource is UTF-8 with TextEncoder semantics', () => {
  assert.deepEqual([...encodeSource('é')], [0xc3, 0xa9]);
  assert.deepEqual([...encodeSource('\uFEFF')], [0xef, 0xbb, 0xbf]);
  // A lone surrogate is not a UTF-8 scalar; TextEncoder emits U+FFFD.
  assert.deepEqual([...encodeSource('\uD800')], [0xef, 0xbf, 0xbd]);
  assert.equal(decodeRange(encodeSource('☀️'), 0, 6), '☀️');
});

for (const fixture of triviaCases) {
  test(fixture.name, () => {
    assertLexes(fixture);
  });
}
