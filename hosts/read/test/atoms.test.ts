// Task 3 red/green gate for the remaining leaf tokens.
//
// The atom classifier is the single leaf seam the Task 4 parser consumes:
// symbols, keywords, booleans, nil, strings, and the number/date/time families
// all come back as one `{ node, diagnostics }` or `null` for a token that is
// not a leaf. Keyword-vs-symbol and reserved-literal spelling are pinned
// against the engine, not against convenience.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { makeAtom } from '../src/atoms.ts';
import { Lexer, type Token, type TokenTag } from '../src/lexer.ts';
import { decodeRange, encodeSource } from '../src/source.ts';
import {
  type AtomCase,
  type LexicalCase,
  atomCases,
  atomRejectCases,
  projectAtom,
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

function assertTokenStream(
  fixture: Pick<AtomCase, 'name' | 'source' | 'tokens'> | LexicalCase,
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

for (const fixture of atomCases) {
  test(fixture.name, () => {
    assertAtomCase(fixture);
  });
}

for (const fixture of atomRejectCases) {
  test(fixture.name, () => {
    const { bytes, tokens } = lex(fixture.source);
    assertTokenStream(fixture, bytes, tokens);
    for (const token of tokens) {
      assert.ok(
        token.tag !== 'number' && token.tag !== 'date' && token.tag !== 'time',
        `${fixture.name}: a ${token.tag} token became a numeric atom`,
      );
      if (token.tag === 'invalid') {
        assert.equal(
          makeAtom(bytes, token),
          null,
          `${fixture.name}: invalid bytes at ${token.start} must not become an atom`,
        );
      }
    }
  });
}

const NON_ATOM_TAGS: ReadonlySet<TokenTag> = new Set([
  'lparen',
  'rparen',
  'lbracket',
  'rbracket',
  'comment_line',
  'comment_block',
  'invalid',
  'eof',
]);

test('makeAtom is null for structural, comment, invalid, and eof tokens', () => {
  const { bytes, tokens } = lex('(a) [b] ; c\n#| d |# 0x : 1e+');
  for (const token of tokens) {
    const result = makeAtom(bytes, token);
    if (NON_ATOM_TAGS.has(token.tag)) {
      assert.equal(result, null, `${token.tag} at ${token.start} must not be an atom`);
    } else {
      assert.ok(result, `${token.tag} at ${token.start} must be an atom`);
    }
  }
});

test('a string diagnostic from the atom seam carries the caller path', () => {
  const { bytes, tokens } = lex('"\\q"');
  const token = tokens[0];
  assert.ok(token);
  const result = makeAtom(bytes, token, ['scene', 'note']);
  assert.ok(result);
  assert.equal(result.node.tag, 'string');
  assert.deepEqual(
    result.diagnostics.map((diagnostic) => diagnostic.path),
    [['scene', 'note']],
  );
});

test('a keyword value excludes its leading colon', () => {
  const { bytes, tokens } = lex(':camera');
  const token = tokens[0];
  assert.ok(token);
  const result = makeAtom(bytes, token);
  assert.ok(result);
  assert.equal(result.node.tag, 'keyword');
  if (result.node.tag === 'keyword') {
    assert.equal(result.node.value, 'camera');
    assert.deepEqual(result.node.span, { start: 0, end: 7 });
  }
});
