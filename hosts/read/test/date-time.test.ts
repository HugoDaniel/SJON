// Task 3 red/green gate for dates and times.
//
// The lexer only emits a `date` token for the exact `YYYY-MM-DD` shape and a
// `time` token for `HH:MM:SS[.fff]`; the reader then applies the same range
// checks as `Date.init` / `Time.init`. Bad components still produce a node
// (defaulted to `0001-01-01` / `00:00:00.000`) plus the engine's diagnostic,
// so downstream walks stay well-formed. Lookalikes (`2026-5-19`,
// `10000-01-01`, `12:34`, `123:45:67`) must stay numbers/keywords.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { makeAtom } from '../src/atoms.ts';
import { Lexer, type Token } from '../src/lexer.ts';
import { decodeRange, encodeSource } from '../src/source.ts';
import { type AtomCase, dateCases, projectAtom, timeCases } from './fixtures/lexical.ts';

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

function assertTokenStream(
  fixture: Pick<AtomCase, 'name' | 'source' | 'tokens'>,
  bytes: Uint8Array,
  tokens: readonly Token[],
): void {
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
    if (expected.text !== undefined) {
      assert.equal(
        decodeRange(bytes, actual.start, actual.end),
        expected.text,
        `${fixture.name}: token ${index} lexeme`,
      );
    }
  });
}

function assertAtomCase(fixture: AtomCase): void {
  const { bytes, tokens } = lex(fixture.source);
  assertTokenStream(fixture, bytes, tokens);
  const token = tokens[fixture.tokenIndex ?? 0];
  assert.ok(token, `${fixture.name}: no token at index ${fixture.tokenIndex ?? 0}`);

  const result = makeAtom(bytes, token);
  assert.ok(result, `${fixture.name}: no atom for a ${token.tag} token`);
  assert.deepEqual(
    result.node.span,
    { start: token.start, end: token.end },
    `${fixture.name}: node span must equal the token span`,
  );
  assert.deepEqual(projectAtom(result.node), fixture.expected, `${fixture.name}: value`);
  assert.deepEqual(result.diagnostics, fixture.diagnostics, `${fixture.name}: diagnostics`);
}

for (const fixture of [...dateCases, ...timeCases]) {
  test(fixture.name, () => {
    assertAtomCase(fixture);
  });
}

test('a date diagnostic carries the caller path', () => {
  const { bytes, tokens } = lex('2026-13-01');
  const token = tokens[0];
  assert.ok(token);
  const result = makeAtom(bytes, token, ['calendar']);
  assert.ok(result);
  assert.deepEqual(
    result.diagnostics.map((diagnostic) => diagnostic.path),
    [['calendar']],
  );
});

test('a time diagnostic carries the caller path', () => {
  const { bytes, tokens } = lex('24:00:00');
  const token = tokens[0];
  assert.ok(token);
  const result = makeAtom(bytes, token, ['clock']);
  assert.ok(result);
  assert.deepEqual(
    result.diagnostics.map((diagnostic) => diagnostic.path),
    [['clock']],
  );
});
