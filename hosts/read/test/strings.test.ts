// Task 2 red/green gate for string lexing and decoding.
//
// Token spans come from the Zig lexer; values and diagnostics come from
// `Parser.decodeString`, which implements `\n \t \r \" \\ \0` only. The
// `\u{…}` case is correction 4 in docs/plans/consumer-api/README.md: the
// engine diagnoses the escape and keeps the text, so this reader must too.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { Lexer, type Token } from '../src/lexer.ts';
import { encodeSource } from '../src/source.ts';
import { decodeStringValue } from '../src/strings.ts';
import {
  type LexicalCase,
  type StringValueCase,
  stringCases,
  stringValueCases,
} from './fixtures/lexical.ts';

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
  });
}

function decodeFixture(fixture: StringValueCase) {
  const { bytes, tokens } = lex(fixture.source);
  const target = tokens[fixture.tokenIndex ?? 0];
  assert.ok(target, `${fixture.name}: no token at index ${fixture.tokenIndex ?? 0}`);
  return { bytes, target, decoded: decodeStringValue(bytes, target) };
}

for (const fixture of stringCases) {
  test(fixture.name, () => {
    assertLexes(fixture);
  });
}

for (const fixture of stringValueCases) {
  test(fixture.name, () => {
    const { decoded } = decodeFixture(fixture);
    assert.equal(decoded.value, fixture.value);
    assert.deepEqual(decoded.diagnostics, fixture.diagnostics);
  });
}

test('decodeStringValue rejects a non-string token', () => {
  const bytes = encodeSource('x');
  assert.throws(() => decodeStringValue(bytes, { tag: 'symbol', start: 0, end: 1 }), TypeError);
});

test('decodeStringValue attributes diagnostics to the caller path', () => {
  const { bytes, tokens } = lex('"\\q"');
  const target = tokens[0];
  assert.ok(target);
  const decoded = decodeStringValue(bytes, target, ['scene', 'note']);
  assert.deepEqual(
    decoded.diagnostics.map((diagnostic) => diagnostic.path),
    [['scene', 'note']],
  );
});
