// Serializer golden: builder IR → canonical `(plugin …)` manifest text.
// Reconstructs the surface of examples/plugins/bounds/plugin.sjon from a
// builder spec and checks the emitted fragments.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import * as s from '../src/builder.ts';

// A bounds-like form: every key references an explicitly-named value-kind,
// mirroring examples/plugins/bounds/plugin.sjon.
function boundsForm() {
  return s.form(
    'profile',
    {
      handle: s.kind('slug', s.string().minLen(3).maxLen(32).pattern('^[a-z][a-z0-9-]*$')),
      email: s.kind('email-string', s.email()),
      homepage: s.kind('url', s.url()).optional(),
      uuid: s.kind('uuid-string', s.uuid()),
      score: s.kind('score', s.number().min(0).max(100)).optional(),
      ratio: s.kind('ratio', s.number().gt(0).max(1)).optional(),
      count: s.kind('count', s.number().min(0).int()).optional(),
      offset: s.kind('aligned', s.number().min(0).int().multipleOf(256)).optional(),
    },
    'bounds',
  );
}

test('manifest declares the plugin name + version', () => {
  const m = boundsForm().manifest();
  assert.match(m, /\(plugin :name bounds :version "1\.0\.0"/);
});

test('numeric value-kinds carry their numeric-bounds', () => {
  const m = boundsForm().manifest();
  assert.match(
    m,
    /\(value-kind :name score :underlying number :numeric \(numeric-bounds :min 0 :max 100\)\)/,
  );
  assert.match(
    m,
    /\(value-kind :name ratio :underlying number :numeric \(numeric-bounds :min 0 :max 1 :exclusive-min true\)\)/,
  );
  assert.match(
    m,
    /\(value-kind :name count :underlying number :numeric \(numeric-bounds :min 0 :integer true\)\)/,
  );
  // `:multiple-of` last, matching the loader's key order in the spec.
  assert.match(
    m,
    /\(value-kind :name aligned :underlying number :numeric \(numeric-bounds :min 0 :integer true :multiple-of 256\)\)/,
  );
});

test('string value-kinds carry format / pattern bounds', () => {
  const m = boundsForm().manifest();
  assert.match(
    m,
    /\(value-kind :name email-string :underlying string :string-bounds \(string-bounds :format email\)\)/,
  );
  assert.match(
    m,
    /\(value-kind :name slug :underlying string :string-bounds \(string-bounds :min-len 3 :max-len 32 :pattern "\^\[a-z\]\[a-z0-9-\]\*\$"\)\)/,
  );
});

test('keys reference their kind by :type with explicit optionality', () => {
  const m = boundsForm().manifest();
  assert.match(m, /\(key :name handle :type slug :optional false\)/);
  assert.match(m, /\(key :name email :type email-string :optional false\)/);
  assert.match(m, /\(key :name homepage :type url :optional true\)/);
  assert.match(m, /\(key :name score :type score :optional true\)/);
});

test('anonymous refined leaves hoist to stable generated names', () => {
  const form = s.form('widget', {
    weight: s.number().min(0).max(10),
    label: s.string().minLen(1),
    role: s.symbolMembers(['admin', 'user']),
    status: s.stringMembers(['active', 'archived']),
  });
  const m = form.manifest();
  assert.match(m, /\(value-kind :name num-min0-max10 :underlying number/);
  assert.match(m, /\(value-kind :name str-min1 :underlying string/);
  assert.match(
    m,
    /\(value-kind :name sym-admin-user :underlying symbol :members \(member-set :values \[admin user\]\)\)/,
  );
  assert.match(
    m,
    /\(value-kind :name enum-active-archived :underlying string :members \(member-set :values \[active archived\]\)\)/,
  );
  assert.match(m, /\(key :name weight :type num-min0-max10/);
});

test('identical anonymous leaves dedupe to one value-kind', () => {
  const form = s.form('pair', {
    lo: s.number().min(0).max(10),
    hi: s.number().min(0).max(10),
  });
  const m = form.manifest();
  const occurrences = m.match(/\(value-kind :name num-min0-max10 /g) ?? [];
  assert.equal(occurrences.length, 1, 'the shared bound should hoist exactly once');
  assert.match(m, /\(key :name lo :type num-min0-max10/);
  assert.match(m, /\(key :name hi :type num-min0-max10/);
});

test('bare primitives + untyped vectors stay builtins (no value-kind)', () => {
  const form = s.form('plain', {
    n: s.number(),
    str: s.string(),
    flag: s.boolean(),
    anything: s.any(),
    tags: s.vector(s.any()),
  });
  const m = form.manifest();
  assert.doesNotMatch(m, /value-kind/);
  assert.match(m, /\(key :name n :type number :optional false\)/);
  assert.match(m, /\(key :name tags :type vector :optional false\)/);
});

test('a typed vector hoists a vector-shape (distinct from untyped :type vector)', () => {
  // s.vector(s.string()) is `string[]`, not `unknown[]`, so it must lower
  // to a vector-shape kind — not the builtin `:type vector`.
  const form = s.form('typed', { tags: s.vector(s.string()) });
  const m = form.manifest();
  assert.match(
    m,
    /\(value-kind :name vec-string :underlying vector :vector \(vector-shape :element string\)\)/,
  );
  assert.match(m, /\(key :name tags :type vec-string :optional false\)/);
});

test('typed/fixed vectors hoist a vector-shape kind', () => {
  const form = s.form('grid', { row: s.vector(s.number(), 3) });
  const m = form.manifest();
  assert.match(
    m,
    /\(value-kind :name vec-number-len3 :underlying vector :vector \(vector-shape :element number :len 3\)\)/,
  );
});

test('cross-ref hoists a symbol value-kind', () => {
  const form = s.form('edge', {
    to: s.kind('node-ref', s.crossRef('node', { nameKey: 'id', acyclic: true })),
  });
  const m = form.manifest();
  assert.match(
    m,
    /\(value-kind :name node-ref :underlying symbol :cross-ref \(cross-ref :target node :name-key id :acyclic true\)\)/,
  );
});

test('provider-route cross-ref emits both keys and its declaration', () => {
  const shader = s.form('shader', { src: s.string() }, 'gfx');
  const bind = s.form(
    'bind',
    { uniform: s.kind('uniform-name', s.crossRef('shader', { provider: 'uniforms' })) },
    'gfx',
  );
  const m = s
    .plugin('gfx', {
      forms: [shader, bind],
      providers: { uniforms: 'Uniform names in a GLSL source string.' },
    })
    .manifest();
  assert.match(
    m,
    /\(cross-ref-provider :name uniforms :description "Uniform names in a GLSL source string\."\)/,
  );
  assert.match(
    m,
    /\(value-kind :name uniform-name :underlying symbol :cross-ref \(cross-ref :target shader :provider uniforms\)\)/,
  );
});

test('a provider declaration without a description emits :name alone', () => {
  const m = s.plugin('gfx', { providers: { uniforms: undefined } }).manifest();
  assert.match(m, /\(cross-ref-provider :name uniforms\)/);
});

test('multi-form plugin emits each form + shared kinds once', () => {
  const node = s.form('node', { id: s.symbol(), label: s.string().optional() }, 'graph');
  const edge = s.form(
    'edge',
    { from: s.kind('node-ref', s.crossRef('node', { nameKey: 'id' })) },
    'graph',
  );
  const plugin = s.plugin('graph', { version: '2.0.0', forms: [node, edge] });
  const m = plugin.manifest();
  assert.match(m, /\(plugin :name graph :version "2\.0\.0"/);
  assert.match(m, /\(form :name node/);
  assert.match(m, /\(form :name edge/);
  assert.match(m, /\(value-kind :name node-ref/);
});
