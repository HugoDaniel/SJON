// Tests for `parseReference` — mirror the in-source tests in
// `src/Resolver.zig` so the second-host enforces the same shape.

import { test } from 'node:test';
import * as assert from 'node:assert/strict';

import { parse } from '../src/parser.ts';
import { parseReference } from '../src/Resolver.ts';
import type { FormNode } from '../src/ast.ts';

function parseSingleRef(src: string) {
  const roots = parse(src);
  assert.equal(roots.length, 1, 'fixture must declare exactly one (use-plugin …) root');
  const root = roots[0]!;
  assert.equal(root.tag, 'form');
  return parseReference(root as FormNode);
}

test('parseReference: bare name', () => {
  const got = parseSingleRef('(use-plugin "shapes")\n');
  assert.equal(got.reference.name, 'shapes');
  assert.equal(got.reference.explicitPath, null);
  assert.equal(got.reference.version, null);
  assert.equal(got.reference.hash, null);
  assert.equal(got.diagnostics.length, 0);
});

test('parseReference: with explicit path, version, and hash', () => {
  const got = parseSingleRef(
    '(use-plugin "shapes" :path "./vendor/shapes.sjon" :version "1.x" :hash "sha256-abc")\n',
  );
  assert.equal(got.reference.name, 'shapes');
  assert.equal(got.reference.explicitPath, './vendor/shapes.sjon');
  assert.equal(got.reference.version, '1.x');
  assert.equal(got.reference.hash, 'sha256-abc');
  assert.equal(got.diagnostics.length, 0);
});

test('parseReference: missing name emits invalid_manifest', () => {
  const got = parseSingleRef('(use-plugin)\n');
  assert.equal(got.diagnostics.length, 1);
  assert.equal(got.diagnostics[0]!.code, 'invalid_manifest');
  assert.equal(got.diagnostics[0]!.severity, 'err');
});

test('parseReference: unknown key emits unknown_key', () => {
  const got = parseSingleRef('(use-plugin "shapes" :registry "x")\n');
  assert.equal(got.reference.name, 'shapes');
  assert.equal(got.diagnostics.length, 1);
  assert.equal(got.diagnostics[0]!.code, 'unknown_key');
});

test('parseReference: non-string :path is invalid_manifest', () => {
  const got = parseSingleRef('(use-plugin "shapes" :path foo)\n');
  assert.equal(got.reference.name, 'shapes');
  assert.equal(got.reference.explicitPath, null);
  assert.equal(got.diagnostics.length, 1);
  assert.equal(got.diagnostics[0]!.code, 'invalid_manifest');
});

test('parseReference: extra positional emits one invalid_manifest, name keeps first', () => {
  const got = parseSingleRef('(use-plugin "shapes" "audio")\n');
  assert.equal(got.reference.name, 'shapes');
  assert.equal(got.diagnostics.length, 1);
  assert.equal(got.diagnostics[0]!.code, 'invalid_manifest');
});

test('parseReference: name span anchors on the literal, not the form head', () => {
  const got = parseSingleRef('(use-plugin "shapes")\n');
  // The opening `(` sits at offset 0; the literal starts after `(use-plugin "`.
  assert.ok(got.reference.span.start > 0);
  assert.ok(got.reference.span.end > got.reference.span.start);
});

test('parseReference: non-string positional emits invalid_manifest, suppresses missing-name', () => {
  const got = parseSingleRef('(use-plugin foo)\n');
  // One diagnostic only — the duplicate "requires a name" follow-up is squelched.
  assert.equal(got.diagnostics.length, 1);
  assert.equal(got.diagnostics[0]!.code, 'invalid_manifest');
});
