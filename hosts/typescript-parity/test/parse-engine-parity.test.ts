// The four parser divergences measured against the engine (P2/P5).
//
// Every expectation here was captured from `zig build cli` + `sjon
// validate` on the inputs below, not read off the Zig source. The
// reference for the state distinctions is `hosts/read/src/lexer.ts` /
// `parser.ts` — the same project's engine-faithful port:
//
//   * `,` is an `.invalid` token, not whitespace (`(a , 1)` reports
//     `invalid token` at path `a/0`);
//   * `#| … |#` is a block comment that closes at the first `|#` and
//     does not nest;
//   * an invalid token's diagnostic carries the *in-progress* slot
//     (`(a 0x 1)` → `a/0`, not `a`);
//   * a head splits on its first *interior* `/` only, so `/head` and
//     `ns/` stay whole.

import { test } from 'node:test';
import * as assert from 'node:assert/strict';

import { parse } from '../src/parser.ts';
import type { FormNode, SymbolNode } from '../src/ast.ts';
import type { Diagnostic } from '../src/diagnostics.ts';

function parseWithDiags(src: string): { roots: readonly unknown[]; diags: Diagnostic[] } {
  const diags: Diagnostic[] = [];
  const roots = parse(src, diags);
  return { roots, diags };
}

function formAt(roots: readonly unknown[], index = 0): FormNode {
  const node = roots[index] as FormNode | undefined;
  assert.equal(node?.tag, 'form');
  return node;
}

// --- 1. comma is an invalid token, not whitespace ---------------------

test('a comma is an invalid token, not whitespace', () => {
  const { roots, diags } = parseWithDiags('(a , 1)');
  assert.equal(diags.length, 1, 'the comma yields exactly one diagnostic');
  assert.equal(diags[0]?.code, 'unspecified');
  assert.equal(diags[0]?.message, 'invalid token');
  assert.equal(diags[0]?.severity, 'err');
  assert.deepEqual(diags[0]?.span, { start: 3, end: 4 }, 'the token spans the comma byte');
  assert.deepEqual(diags[0]?.path, ['a', '0'], 'attributed to the in-progress slot');

  // Recovery: the comma is skipped and `1` still attaches as the form's
  // first positional child, exactly as the engine's `.invalid` branch
  // does (collection over abort).
  const form = formAt(roots);
  assert.equal(form.children.length, 1);
  assert.equal(form.children[0]?.tag, 'number');
});

test('a comma between a key and its value reports the pending key', () => {
  // Engine capture: `(a :k , 1)` → `invalid token` at path `a/k`, then
  // `1` pairs with `:k`.
  const { roots, diags } = parseWithDiags('(a :k , 1)');
  assert.equal(diags.length, 1);
  assert.deepEqual(diags[0]?.path, ['a', 'k']);
  const form = formAt(roots);
  assert.equal(form.children.length, 1);
  assert.equal(form.children[0]?.tag, 'kvpair');
});

// --- 2. block comments -------------------------------------------------

test('a block comment is skipped between tokens', () => {
  // Engine capture: no parse diagnostic; `1` is the only child.
  const { roots, diags } = parseWithDiags('(a #| hi |# 1)');
  assert.equal(diags.length, 0);
  const form = formAt(roots);
  assert.equal(form.children.length, 1);
  assert.equal(form.children[0]?.tag, 'number');
});

test('a block comment closes at the first `|#` and does not nest', () => {
  // `#| one #| two |#` is one comment (the inner `#|` is body text);
  // `three` and `|#` are then ordinary tokens.
  const { roots, diags } = parseWithDiags('(a #| one #| two |# three |# 1)');
  assert.equal(diags.length, 0);
  const form = formAt(roots);
  assert.equal(form.children.length, 3);
  assert.equal((form.children[0] as SymbolNode).text, 'three');
  assert.equal((form.children[1] as SymbolNode).text, '|#');
  assert.equal(form.children[2]?.tag, 'number');
});

test('a hash that does not open a block comment is an invalid token', () => {
  // Engine capture: `(a # 1)` → `invalid token` at path `a/0`; `#` alone
  // is a `.block_hash` token that never found its `|`, not a symbol.
  const { roots, diags } = parseWithDiags('(a # 1)');
  assert.equal(diags.length, 1);
  assert.equal(diags[0]?.message, 'invalid token');
  assert.deepEqual(diags[0]?.path, ['a', '0']);
  assert.equal(formAt(roots).children.length, 1);
});

test('an unterminated block comment is one invalid token to end of input', () => {
  // Engine capture: `invalid token` at path `a/0`, then the form is
  // closed at EOF by the usual `unclosed delimiter` recovery.
  const src = '(a #| never closed';
  const { roots, diags } = parseWithDiags(src);
  assert.equal(diags.length, 2);
  assert.equal(diags[0]?.message, 'invalid token');
  assert.deepEqual(diags[0]?.path, ['a', '0']);
  assert.deepEqual(diags[0]?.span, { start: 3, end: src.length });
  assert.equal(diags[1]?.message, 'unclosed delimiter at end of input');
  assert.deepEqual(diags[1]?.path, ['a']);
  assert.equal(formAt(roots).children.length, 0);
});

// --- 3. in-progress path slot -----------------------------------------

test('an invalid `0x` prefix reports the in-progress slot in its path', () => {
  // Engine capture: `(a 0x 1)` → `invalid token` at path `a/0`;
  // the port used to report `a`.
  const { roots, diags } = parseWithDiags('(a 0x 1)');
  assert.equal(diags.length, 1);
  assert.deepEqual(diags[0]?.path, ['a', '0']);
  // Recovery: `1` is the first positional child, `GG`-style tails would
  // be symbols — here there is no 0x node.
  const form = formAt(roots);
  assert.equal(form.children.length, 1);
  assert.equal(form.children[0]?.tag, 'number');
});

// --- 4. qualified-head splitting --------------------------------------

test('a leading slash does not split the head', () => {
  // Engine capture: `(/head 1)` → unknown form `/head`, path `/head`.
  const form = formAt(parse('(/head 1)'));
  assert.equal(form.head, '/head');
  assert.equal(form.namespace, null);
});

test('a trailing slash does not split the head', () => {
  // Engine capture: `(ns/ 1)` → unknown form `ns/`, path `ns/`.
  const form = formAt(parse('(ns/ 1)'));
  assert.equal(form.head, 'ns/');
  assert.equal(form.namespace, null);
});

test('the first interior slash splits the head', () => {
  // Engine capture: `(a/b/c 1)` → namespace `a`, head `b/c`.
  const form = formAt(parse('(a/b/c 1)'));
  assert.equal(form.namespace, 'a');
  assert.equal(form.head, 'b/c');
});

test('a doubled interior slash splits at the first one', () => {
  // `splitNamespace` takes the first slash; the remainder stays in the
  // head even when it begins with another slash.
  const form = formAt(parse('(a//b 1)'));
  assert.equal(form.namespace, 'a');
  assert.equal(form.head, '/b');
});
