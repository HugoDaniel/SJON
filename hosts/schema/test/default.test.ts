// .default(v): the cross-host default surface. A defaulted key is optional in
// the input (s.input / create) but required in the output (s.infer); the
// manifest carries `:default <literal>`; create fills it.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import * as s from '../src/builder.ts';
import * as v from '../src/value-ctor.ts';

function expectAssignableTo<Target>(_value: Target): void {
  void _value;
}

const Doc = s.form('doc', {
  id: s.string(), // required, no default
  title: s.string().default('Untitled'),
  count: s.number().default(0),
});

test('.default(v) records the value without marking the node optional', () => {
  const titled = s.string().default('Untitled');
  assert.equal(titled._def.default, 'Untitled');
  assert.equal(titled._def.isOptional, false); // default ≠ optional
  // Immutability: the base node is untouched.
  const base = s.number();
  base.default(0);
  assert.equal(base._def.default, undefined);
});

test('create fills declared defaults for omitted keys', () => {
  assert.deepEqual(Doc.create({ id: 'a' }), {
    $form: 'doc',
    $ns: 'doc',
    id: 'a',
    title: 'Untitled',
    count: 0,
  });
});

test('a provided value overrides its default', () => {
  assert.deepEqual(Doc.create({ id: 'a', title: 'Hi', count: 7 }), {
    $form: 'doc',
    $ns: 'doc',
    id: 'a',
    title: 'Hi',
    count: 7,
  });
});

test('filled defaults are deep-cloned (callers cannot mutate the schema)', () => {
  const Grid = s.form('grid', { origin: s.vector(s.number(), 2).default([0, 0]) });
  const a = Grid.create({}) as unknown as { origin: number[] };
  const b = Grid.create({}) as unknown as { origin: number[] };
  a.origin[0] = 99;
  assert.deepEqual(b.origin, [0, 0]); // unaffected
});

test('the manifest emits :default <literal> alongside :optional false', () => {
  const m = Doc.manifest();
  assert.match(m, /\(key :name title :type string :optional false :default "Untitled"\)/);
  assert.match(m, /\(key :name count :type number :optional false :default 0\)/);
  // The non-defaulted required key carries no :default.
  assert.match(m, /\(key :name id :type string :optional false\)/);
  assert.doesNotMatch(m, /:name id[^)]*:default/);
});

test('symbol + vector defaults serialize into the manifest', () => {
  const Cfg = s.form('cfg', {
    mode: s.symbolMembers(['a', 'b'] as const).default(v.sym('a')),
    origin: s.vector(s.number(), 2).default([0, 0]),
  });
  const m = Cfg.manifest();
  assert.match(m, /:name mode[^)]*:default a\)/);
  assert.match(m, /:name origin[^)]*:default \[0 0\]\)/);
  assert.deepEqual(Cfg.create({}), {
    $form: 'cfg',
    $ns: 'cfg',
    mode: { $sym: 'a' },
    origin: [0, 0],
  });
});

// --- Type-level: input-optional vs output-required -------------------------

function _typeSplit(): void {
  type Out = s.infer<typeof Doc>;
  type In = s.input<typeof Doc>;

  // Output keeps defaulted keys REQUIRED (matches the exporter).
  const out = Doc.create({ id: 'a' });
  expectAssignableTo<Out>(out);
  expectAssignableTo<string>(out.title);
  expectAssignableTo<number>(out.count);

  // Input makes defaulted keys OPTIONAL — omitting title/count is fine.
  const inOnlyId: In = { $form: 'doc', $ns: 'doc', id: 'a' };
  void inOnlyId;
  Doc.create({ id: 'a' }); // omitting both defaulted keys compiles

  // @ts-expect-error the non-defaulted required key (id) is still required
  Doc.create({ title: 'x' });
  // @ts-expect-error output type still requires the defaulted key `title`
  const outMissing: Out = { $form: 'doc', $ns: 'doc', id: 'a', count: 0 };
  void outMissing;
  // @ts-expect-error default value must match the field type
  s.number().default('not a number');
}
void _typeSplit;
