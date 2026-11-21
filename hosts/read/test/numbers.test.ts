// Task 3 red/green gate for exact numeric classification.
//
// Every fixture comes from the engine: token spans from `src/Lexer.zig`,
// classification (i64/u64/unit/f64) from `sjon_node_table` and
// `sjon_to_json`. The suite pins bigint-first accumulation at both i64/u64
// boundaries, the overflow diagnostic, unit nullability, hex semicolons, and
// number-shaped spellings a broader JS numeric regex would misread.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { Lexer, type Token } from '../src/lexer.ts';
import { classifyNumber } from '../src/numbers.ts';
import { decodeRange, encodeSource } from '../src/source.ts';
import { type AtomCase, numberCases, projectAtom } from './fixtures/lexical.ts';

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

function assertNumberCase(fixture: AtomCase): void {
  const { bytes, tokens } = lex(fixture.source);
  assertTokenStream(fixture, bytes, tokens);
  const token = tokens[fixture.tokenIndex ?? 0];
  assert.ok(token, `${fixture.name}: no token at index ${fixture.tokenIndex ?? 0}`);
  assert.equal(token.tag, 'number', `${fixture.name}: expected a number token`);

  const result = classifyNumber(bytes, token);
  assert.deepEqual(
    result.node.span,
    { start: token.start, end: token.end },
    `${fixture.name}: node span must equal the token span`,
  );
  assert.deepEqual(projectAtom(result.node), fixture.expected, `${fixture.name}: value`);
  assert.deepEqual(result.diagnostics, fixture.diagnostics, `${fixture.name}: diagnostics`);
}

for (const fixture of numberCases) {
  test(fixture.name, () => {
    assertNumberCase(fixture);
  });
}

test('classifyNumber rejects a non-number token', () => {
  const bytes = encodeSource('x');
  assert.throws(() => classifyNumber(bytes, { tag: 'symbol', start: 0, end: 1 }), TypeError);
});

test('overflow diagnostics carry the caller path', () => {
  const { bytes, tokens } = lex('18446744073709551616');
  const token = tokens[0];
  assert.ok(token);
  const result = classifyNumber(bytes, token, ['layout', 'size']);
  assert.deepEqual(
    result.diagnostics.map((diagnostic) => diagnostic.path),
    [['layout', 'size']],
  );
});

test('negative zero keeps its sign in the f64 view and zero in integer', () => {
  const { bytes, tokens } = lex('-0');
  const token = tokens[0];
  assert.ok(token);
  const result = classifyNumber(bytes, token);
  assert.equal(result.node.tag, 'number');
  if (result.node.tag !== 'number') return;
  assert.ok(Object.is(result.node.value, -0), 'value must be -0');
  assert.equal(result.node.integer, 0n);
});

test('an exactly representable integer still exposes its bigint', () => {
  const { bytes, tokens } = lex('1_000_000');
  const token = tokens[0];
  assert.ok(token);
  const result = classifyNumber(bytes, token);
  assert.equal(result.node.tag, 'number');
  if (result.node.tag === 'number') {
    assert.deepEqual(result.node.integer, 1_000_000n);
  }
});
