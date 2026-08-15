// Builder runtime: node construction, immutability, optional markers.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import * as s from '../src/builder.ts';

test('primitives carry the right shape kind', () => {
  assert.equal(s.any()._def.shape.kind, 'any');
  assert.equal(s.nil()._def.shape.kind, 'nil');
  assert.equal(s.boolean()._def.shape.kind, 'boolean');
  assert.equal(s.number()._def.shape.kind, 'number');
  assert.equal(s.string()._def.shape.kind, 'string');
  assert.equal(s.symbol()._def.shape.kind, 'symbol');
  assert.equal(s.expr()._def.shape.kind, 'expr');
  assert.equal(s.formAny()._def.shape.kind, 'form_any');
});

test('a bare number/string has no bounds (serializes as a builtin)', () => {
  assert.deepEqual(s.number()._def.shape, { kind: 'number' });
  assert.deepEqual(s.string()._def.shape, { kind: 'string' });
});

test('numeric refinements accumulate immutably', () => {
  const base = s.number();
  const refined = base.min(0).max(100).int();
  // Original untouched.
  assert.deepEqual(base._def.shape, { kind: 'number' });
  assert.deepEqual(refined._def.shape, {
    kind: 'number',
    bounds: { min: 0, max: 100, integer: true },
  });
});

test('gt/lt set the exclusive flags', () => {
  assert.deepEqual(s.number().gt(0)._def.shape, {
    kind: 'number',
    bounds: { min: 0, exclusiveMin: true },
  });
  assert.deepEqual(s.number().lt(1)._def.shape, {
    kind: 'number',
    bounds: { max: 1, exclusiveMax: true },
  });
});

test('string refinements + presets', () => {
  assert.deepEqual(s.string().minLen(3).maxLen(8)._def.shape, {
    kind: 'string',
    bounds: { minLen: 3, maxLen: 8 },
  });
  assert.deepEqual(s.email()._def.shape, { kind: 'string', bounds: { format: 'email' } });
  assert.equal(s.email()._def.suggestedKind, 'email');
  assert.deepEqual(s.url()._def.shape, { kind: 'string', bounds: { format: 'uri' } });
  assert.deepEqual(s.slug()._def.shape, {
    kind: 'string',
    bounds: { pattern: '^[a-z][a-z0-9-]*$' },
  });
});

test('.optional() flags the node and leaves the original alone', () => {
  const base = s.string();
  const opt = base.optional();
  assert.equal(base._def.isOptional, false);
  assert.equal(opt._def.isOptional, true);
});

test('enums capture members in order', () => {
  assert.deepEqual(s.symbolMembers(['admin', 'user'])._def.shape, {
    kind: 'symbol_members',
    members: ['admin', 'user'],
  });
  assert.deepEqual(s.stringMembers(['active', 'archived'])._def.shape, {
    kind: 'string_members',
    members: ['active', 'archived'],
  });
});

test('vectors record element shape and optional length', () => {
  assert.deepEqual(s.vector(s.number())._def.shape, {
    kind: 'vector',
    element: { kind: 'number' },
  });
  assert.deepEqual(s.vector(s.string(), 3)._def.shape, {
    kind: 'vector',
    element: { kind: 'string' },
    len: 3,
  });
});

test('s.kind stamps an explicit, authoritative name', () => {
  const score = s.kind('score', s.number().min(0).max(100));
  assert.equal(score._def.suggestedKind, 'score');
  assert.equal(score._def.explicitKind, true);
});

test('s.kind preserves the wrapped node refinement methods', () => {
  // Refining AFTER kind must work — kind used to rebuild via a bare leaf,
  // dropping the number/string method surface, so `.min` threw at call time.
  const score = s.kind('score', s.number()).min(0).max(100);
  assert.equal(score._def.suggestedKind, 'score');
  assert.equal(score._def.explicitKind, true);
  assert.deepEqual(score._def.shape, { kind: 'number', bounds: { min: 0, max: 100 } });

  const handle = s.kind('handle', s.string()).minLen(3).pattern('^[a-z]+$');
  assert.equal(handle._def.suggestedKind, 'handle');
  assert.deepEqual(handle._def.shape, {
    kind: 'string',
    bounds: { minLen: 3, pattern: '^[a-z]+$' },
  });
});

test('crossRef captures target + refinements', () => {
  assert.deepEqual(s.crossRef('node', { nameKey: 'id', acyclic: true })._def.shape, {
    kind: 'cross_ref',
    crossRef: { target: 'node', nameKey: 'id', acyclic: true },
  });
});

test('crossRef captures the provider route', () => {
  assert.deepEqual(s.crossRef('shader', { provider: 'uniforms', sourceKey: 'body' })._def.shape, {
    kind: 'cross_ref',
    crossRef: { target: 'shader', provider: 'uniforms', sourceKey: 'body' },
  });
});

test('crossRef rejects the three route contradictions at the call site', () => {
  // Unconstructible beats diagnosable: the stack trace points at the
  // builder call, not at a manifest three layers down.
  assert.throws(
    () => s.crossRef('shader', { provider: 'uniforms', nameKey: 'id' }),
    /exclusive extraction routes/,
  );
  assert.throws(
    () => s.crossRef('shader', { provider: 'uniforms', acyclic: true }),
    /identity-route only/,
  );
  assert.throws(() => s.crossRef('shader', { sourceKey: 'body' }), /needs a `provider`/);
});

test('crossRef allows acyclic: false alongside a provider', () => {
  // The exclusion is about an active cycle check, not the key's presence.
  assert.doesNotThrow(() => s.crossRef('shader', { provider: 'uniforms', acyclic: false }));
});

test('form def collects keys with namespace defaulting to head', () => {
  const profile = s.form('profile', { handle: s.slug(), email: s.email().optional() });
  assert.equal(profile._def.head, 'profile');
  assert.equal(profile._def.ns, 'profile');
  assert.deepEqual(
    profile._def.keys.map((k) => [k.name, k.def.isOptional]),
    [
      ['handle', false],
      ['email', true],
    ],
  );

  const ns = s.form('profile', { handle: s.slug() }, 'bounds');
  assert.equal(ns._def.ns, 'bounds');
});
