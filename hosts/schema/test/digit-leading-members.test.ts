// Digit-leading enum members (`1d`, `2d`, `2d-array`, `50%`) — the spelling
// the WebGPU enums use, which no bare SJON symbol can express.
//
// Two things have to line up, and they pull in opposite directions:
//
//  - the *manifest* must declare `2d` bare, because `member-name` accepts a
//    symbol or a number and a quoted `"2d"` is neither; and
//  - the *value* type must be `SjonUnit`, not `Symbol_`, because `2d` lexes as
//    a unit-bearing number, so a document carries `{$num:[2,"d"]}`.
//
// The end-to-end proof that both are right lives in
// `hosts/web/test/schema-builder.test.ts`, which runs a builder-authored
// manifest through `sjon.wasm`. These tests are the local half.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import * as s from '../src/builder.ts';
import * as v from '../src/value-ctor.ts';
import { serializeValue } from '../src/value.ts';
import type { SjonUnit, Symbol_ } from '../src/infer.ts';

function expectAssignableTo<Target>(_value: Target): void {
  void _value;
}

test('a digit-leading member is stored, and serialized, bare', () => {
  const Texture = s.form('texture', {
    dimension: s.symbolMembers(['1d', '2d', '3d'] as const),
  });
  assert.match(Texture.manifest(), /:members \(member-set :values \[1d 2d 3d\]\)/);
});

test('a hyphen-joined and a percent unit are both member spellings', () => {
  const View = s.form('view', {
    dimension: s.symbolMembers(['2d', '2d-array', 'cube'] as const),
    zoom: s.symbolMembers(['50%', '100%'] as const),
  });
  const text = View.manifest();
  assert.match(text, /:values \[2d 2d-array cube\]/);
  assert.match(text, /:values \[50% 100%\]/);
});

test('a digit-leading spelling is canonicalised the way the loader canonicalises it', () => {
  // `ManifestLoader.parseMemberName` formats the magnitude and re-appends the
  // unit, so `02d` and `2.0d` both *declare* the member `2d` — and every
  // diagnostic about it says `2d`. Writing the author's spelling through would
  // make the manifest disagree with the diagnostics.
  // Three spellings, three *different* members — `02d` and `2.0d` would
  // canonicalise onto each other, which is a duplicate rather than a
  // canonicalisation case and has its own test below.
  const node = s.symbolMembers(['02d', '3.0d', '1_0d'] as const);
  assert.deepEqual(node._def.shape, {
    kind: 'symbol_members',
    members: ['2d', '3d', '10d'],
  });
});

test('two spellings of one member are rejected at the call site', () => {
  // The engine refuses the emitted manifest (`invalid_manifest`, "declares
  // duplicate member `2d`"), so the only question is whether the author
  // hears about it here or at load time. Canonicalisation is what makes this
  // worth catching: `[2d 2.0d]` reads as two members by eye.
  assert.throws(() => s.symbolMembers(['2d', '2.0d'] as const), /declares member "2d" twice/);
  assert.throws(() => s.symbolMembers(['02d', '2d'] as const), /declares member "2d" twice/);
  // A byte-equal repeat is the same mistake, more visibly.
  assert.throws(() => s.symbolMembers(['a', 'b', 'a'] as const), /declares member "a" twice/);
});

test('an ordinary symbol member is untouched', () => {
  const node = s.symbolMembers(['admin', 'user', '_internal', 'kebab-case'] as const);
  assert.deepEqual(node._def.shape, {
    kind: 'symbol_members',
    members: ['admin', 'user', '_internal', 'kebab-case'],
  });
});

test('a spelling the loader would reject throws where it was written', () => {
  // No unit — a bare number is not a member spelling.
  assert.throws(() => s.symbolMembers(['1', '2']), /carries no unit/);
  // Fractional magnitude — matching is integer-keyed, so it could never match.
  assert.throws(() => s.symbolMembers(['2.5d']), /whole magnitude/);
  // A unit that would not lex as one token: the digit ends the unit, so `2dx9`
  // is `2dx` then `9`, and `2d-3` is `2d` then `-3`.
  assert.throws(() => s.symbolMembers(['2dx9']), /would not lex as one token/);
  assert.throws(() => s.symbolMembers(['2d-3']), /would not lex as one token/);
  // Not digit-leading and not a bare symbol either — `atom` would have quoted
  // it into a string member the manifest grammar cannot carry.
  assert.throws(() => s.symbolMembers(['hello world']), /neither a bare symbol nor/);
  assert.throws(() => s.symbolMembers(['']), /cannot be empty/);
});

test('the value a digit-leading slot takes is a unit-bearing number', () => {
  // `v.sym('2d')` is the wrong constructor and says so — it would emit `2d` as
  // a symbol, which is not what `2d` lexes as.
  assert.throws(() => v.sym('2d'), /must start with a letter/);
  assert.equal(serializeValue(v.unit(2, 'd')), '2d');
  assert.equal(serializeValue(v.unit(2, 'd-array')), '2d-array');
});

// The load-bearing assertions (compile-time; `tsc --noEmit` is the gate):
function _typeConformance(): void {
  const Dimension = s.symbolMembers(['1d', '2d', '3d'] as const);
  const View = s.symbolMembers(['2d', '2d-array', 'cube', 'cube-array'] as const);
  const Role = s.symbolMembers(['admin', 'user'] as const);

  // Digit-leading → `SjonUnit`, keyed on the unit the spellings share.
  expectAssignableTo<SjonUnit<'d'>>(null as unknown as (typeof Dimension)['_out']);
  expectAssignableTo<(typeof Dimension)['_out']>(v.unit(2, 'd'));

  // A mixed set is a union of both brands, member by member.
  expectAssignableTo<SjonUnit<'d'> | SjonUnit<'d-array'> | Symbol_<'cube'> | Symbol_<'cube-array'>>(
    null as unknown as (typeof View)['_out'],
  );
  expectAssignableTo<(typeof View)['_out']>(v.unit(2, 'd-array'));
  expectAssignableTo<(typeof View)['_out']>(v.sym('cube'));

  // An all-symbol set is unchanged — this is the regression that matters most,
  // since every existing member set is one.
  expectAssignableTo<Symbol_<'admin'> | Symbol_<'user'>>(null as unknown as (typeof Role)['_out']);
  expectAssignableTo<(typeof Role)['_out']>(v.sym('admin'));
}

test('type conformance (compile-time)', () => {
  assert.equal(typeof _typeConformance, 'function');
});
