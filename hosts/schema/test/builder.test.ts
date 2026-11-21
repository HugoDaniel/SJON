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

test('multipleOf carries the divisor, and refuses a non-positive one', () => {
  assert.deepEqual(s.number().min(0).int().multipleOf(256)._def.shape, {
    kind: 'number',
    bounds: { min: 0, integer: true, multipleOf: 256 },
  });
  // The loader refuses both of these (`numeric_bounds_invalid`), so the
  // builder refuses them first rather than emitting an unloadable manifest.
  assert.throws(() => s.number().multipleOf(0), /needs a positive divisor/);
  assert.throws(() => s.number().multipleOf(-256), /needs a positive divisor/);
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

test('repr and unit rejection ride beside numeric bounds, immutably', () => {
  const base = s.number();
  const refined = base.repr('u32').rejectUnits().min(0).int();
  // Original untouched — every refinement returns a fresh shape.
  assert.deepEqual(base._def.shape, { kind: 'number' });
  assert.deepEqual(refined._def.shape, {
    kind: 'number',
    bounds: { min: 0, integer: true },
    repr: 'u32',
    rejectUnits: true,
  });
});

test('repr accepts exactly the five GPU tags and refuses anything else at the call site', () => {
  for (const tag of ['f32', 'u32', 'i32', 'u16', 'f16'] as const) {
    assert.deepEqual(s.number().repr(tag)._def.shape, { kind: 'number', repr: tag });
  }
  // The tag set is closed at runtime too: a JS caller passing `u8` must not get
  // as far as serializing a manifest the loader would refuse.
  assert.throws(
    () => (s.number().repr as (tag: string) => unknown)('u8'),
    /u8.*f32, u32, i32, u16, f16/,
  );
});

test('every numeric refinement preserves a selected representation', () => {
  const repr = s.number().repr('f16').rejectUnits();
  const variants = [
    repr.min(0),
    repr.max(1),
    repr.gt(0),
    repr.lt(1),
    repr.int(),
    repr.multipleOf(2),
    repr.optional(),
    repr.describe('half'),
  ];
  for (const node of variants) {
    assert.equal(node._def.shape.kind, 'number');
    if (node._def.shape.kind !== 'number') continue;
    assert.equal(node._def.shape.repr, 'f16');
    assert.equal(node._def.shape.rejectUnits, true);
  }
  assert.deepEqual(repr._def.shape, { kind: 'number', repr: 'f16', rejectUnits: true });
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
    crossRef: { targets: ['node'], nameKey: 'id', acyclic: true },
  });
});

test('crossRef captures the provider route', () => {
  assert.deepEqual(s.crossRef('shader', { provider: 'uniforms', sourceKey: 'body' })._def.shape, {
    kind: 'cross_ref',
    crossRef: { targets: ['shader'], provider: 'uniforms', sourceKey: 'body' },
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

test('crossRef takes a target group, and one target keeps the bare spelling', () => {
  // Both spellings normalise to a list, so `_def` cannot tell them apart —
  // matching the engine's loader, where `:target [phrase]` is a
  // single-target cross-ref rather than a group of one.
  assert.deepEqual(s.crossRef(['render-pipeline', 'compute-pipeline'])._def.shape, {
    kind: 'cross_ref',
    crossRef: { targets: ['render-pipeline', 'compute-pipeline'] },
  });
  assert.deepEqual(s.crossRef(['phrase'])._def.shape, s.crossRef('phrase')._def.shape);
});

test('crossRef rejects what a target group cannot carry', () => {
  assert.throws(() => s.crossRef([]), /at least one target/);
  assert.throws(() => s.crossRef(['a', 'b', 'a']), /twice/);
  assert.throws(() => s.crossRef(['a', 'b'], { acyclic: true }), /needs a single target/);
  assert.throws(() => s.crossRef(['a', 'b'], { provider: 'p' }), /needs a single target/);
  // A single target is unaffected by any of it.
  assert.doesNotThrow(() => s.crossRef('a', { acyclic: true }));
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

test('form options: closed, no-positional is the unchanged default', () => {
  // Both the omitted third argument and the legacy string keep the old FormDef:
  // no openness, no positional slot. The object form must normalize to the same
  // IR, not a parallel one.
  const implied = s.form('profile', { handle: s.slug() });
  assert.equal(implied._def.ns, 'profile');
  assert.equal(implied._def.open, false);
  assert.deepEqual(implied._def.positional, { kind: 'none' });

  const legacy = s.form('profile', { handle: s.slug() }, 'bounds');
  assert.equal(legacy._def.ns, 'bounds');
  assert.equal(legacy._def.open, false);
  assert.deepEqual(legacy._def.positional, { kind: 'none' });

  const explicit = s.form('profile', { handle: s.slug() }, { ns: 'bounds', open: false });
  assert.equal(explicit._def.ns, 'bounds');
  assert.equal(explicit._def.open, false);
  assert.deepEqual(explicit._def.positional, { kind: 'none' });
});

test('form options: ns/open/positional normalize into the existing FormDef IR', () => {
  const note = s.form('note', { text: s.string() }, { ns: 'studio', open: true });
  assert.equal(note._def.ns, 'studio');
  assert.equal(note._def.open, true);
  assert.deepEqual(note._def.positional, { kind: 'none' });

  const anyLines = s.form('lines', { title: s.string() }, { positional: 'any' });
  assert.equal(anyLines._def.open, false);
  assert.deepEqual(anyLines._def.positional, { kind: 'any' });

  const typedLines = s.form('lines', { title: s.string() }, { positional: s.string() });
  assert.equal(typedLines._def.open, false);
  assert.equal(typedLines._def.positional.kind, 'typed');
  assert.deepEqual(
    typedLines._def.positional.kind === 'typed' ? typedLines._def.positional.element.shape : null,
    { kind: 'string' },
  );
});
