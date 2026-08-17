// End-to-end: the @sjon/schema fluent builder over the WASM backend.
// Author a form in TS, validate real SJON text + JS objects, and get
// typed data (or SjonValidationError) back — all through sjon.wasm.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import { createWasmBackend } from '../SjonSchemaBackend.ts';
import { s, v, SjonValidationError } from '@sjon/schema';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

async function backend() {
  const host = await SjonHost.load(wasmPath);
  return createWasmBackend(host);
}

function profileSchema() {
  return s.form(
    'profile',
    {
      handle: s.slug(),
      email: s.email(),
      score: s.number().min(0).max(100).optional(),
      bio: s.string().optional(),
    },
    'bounds',
  );
}

test('manifest() round-trips through the host with no diagnostics', async () => {
  const be = await backend();
  const Profile = profileSchema();
  const outcome = be.validate(Profile.manifest());
  assert.deepEqual(
    outcome.diagnostics.filter((d) => d.severity === 'err'),
    [],
    'the generated manifest should be a clean plugin declaration',
  );
});

test('.parse returns typed data for a valid document', async () => {
  s.use(await backend());
  const Profile = profileSchema();
  const data = Profile.parse('(bounds/profile :handle "ada" :email "ada@example.com" :score 42)');
  assert.equal(data.$form, 'profile');
  assert.equal(data.$ns, 'bounds');
  assert.equal(data.handle, 'ada');
  assert.equal(data.email, 'ada@example.com');
  assert.equal(data.score, 42);
});

test('.parse stamps $ns/$form even when the source form is unqualified', async () => {
  s.use(await backend());
  const Profile = profileSchema();
  const data = Profile.parse('(profile :handle "ada" :email "ada@example.com")');
  assert.equal(data.$ns, 'bounds');
  assert.equal(data.$form, 'profile');
  assert.equal(data.handle, 'ada');
});

test('.parse throws SjonValidationError on an out-of-range value', async () => {
  s.use(await backend());
  const Profile = profileSchema();
  assert.throws(
    () => Profile.parse('(bounds/profile :handle "ada" :email "ada@example.com" :score 999)'),
    (err: unknown) => {
      assert.ok(err instanceof SjonValidationError);
      assert.ok(
        err.errors.some((d) => d.code === 'number_above_max'),
        `expected number_above_max, got ${err.errors.map((d) => d.code).join(', ')}`,
      );
      return true;
    },
  );
});

test('.safeParse returns a discriminated result', async () => {
  s.use(await backend());
  const Profile = profileSchema();

  const ok = Profile.safeParse('(bounds/profile :handle "ada" :email "ada@example.com")');
  assert.equal(ok.success, true);
  if (ok.success) assert.equal(ok.data.handle, 'ada');

  const bad = Profile.safeParse('(bounds/profile :handle "ada")'); // missing required email
  assert.equal(bad.success, false);
  if (!bad.success) {
    assert.ok(bad.error.errors.some((d) => d.code === 'missing_required_key'));
  }
});

test('.parseValue validates a JS object and returns it typed', async () => {
  s.use(await backend());
  const Profile = profileSchema();
  const value = {
    $form: 'profile',
    $ns: 'bounds',
    handle: 'ada',
    email: 'ada@example.com',
    score: 10,
  } as const;
  const data = Profile.parseValue(value);
  assert.equal(data.handle, 'ada');
  assert.equal(data.score, 10);
});

test('.safeParseValue surfaces diagnostics for a bad object', async () => {
  s.use(await backend());
  const Profile = profileSchema();
  const result = Profile.safeParseValue({
    $form: 'profile',
    $ns: 'bounds',
    handle: 'ada',
    email: 'ada@example.com',
    score: 999, // exceeds max 100
  });
  assert.equal(result.success, false);
  if (!result.success) {
    assert.ok(result.error.errors.some((d) => d.code === 'number_above_max'));
  }
});

test('.toDts emits a TypeScript declaration for the form', async () => {
  s.use(await backend());
  const Profile = profileSchema();
  const dts = Profile.toDts();
  assert.match(dts, /export interface Bounds_Profile/);
  assert.match(dts, /\$form: "profile"/);
  assert.match(dts, /\$ns: "bounds"/);
});

// --- digit-leading members -------------------------------------------------
//
// `s.symbolMembers(['1d','2d','3d'])` writes a manifest the *engine* has to
// accept and then match against, which is the half `hosts/schema`'s own tests
// cannot reach: they have no engine (zero deps, by design). So the builder,
// the manifest grammar, and the validator's digit-leading escape are checked
// here, together, against the real WASM.

function textureSchema() {
  return s.form(
    'texture',
    {
      name: s.string(),
      dimension: s.symbolMembers(['1d', '2d', '3d'] as const),
      view: s.symbolMembers(['2d', '2d-array', 'cube'] as const).optional(),
    },
    'gpu',
  );
}

test('a builder-authored digit-leading member set is a clean manifest', async () => {
  const be = await backend();
  const outcome = be.validate(textureSchema().manifest());
  assert.deepEqual(
    outcome.diagnostics.filter((d) => d.severity === 'err'),
    [],
    'the `2d` / `2d-array` spellings must load as member names, not as strings',
  );
});

test('a digit-leading member validates, and a near-miss is not_member', async () => {
  s.use(await backend());
  const Texture = textureSchema();

  const ok = Texture.safeParse('(gpu/texture :name "albedo" :dimension 2d :view 2d-array)');
  assert.equal(ok.success, true, JSON.stringify(ok.success ? null : ok.error.errors));

  // `4d` is the right *shape* (a unit-bearing number) and the wrong member, so
  // the slot reports `not_member` rather than `wrong_underlying` — the widening
  // the escape exists to produce.
  const near = Texture.safeParse('(gpu/texture :name "albedo" :dimension 4d)');
  assert.equal(near.success, false);
  if (!near.success) {
    assert.ok(
      near.error.errors.some((d) => d.code === 'not_member'),
      `expected not_member, got ${near.error.errors.map((d) => d.code).join(', ')}`,
    );
  }
});

test('a digit-leading member accepts the unit value ctor and round-trips', async () => {
  s.use(await backend());
  const Texture = textureSchema();
  const data = Texture.parseValue({
    $form: 'texture',
    $ns: 'gpu',
    name: 'albedo',
    dimension: v.unit(2, 'd'),
  } as const);
  // The engine hands the value back as the number-with-unit it is on the wire —
  // `{$num:[2,"d"]}` — not as the symbol the spelling looks like.
  assert.deepEqual(data.dimension, { $num: [2, 'd'] });
});

// --- multi-target cross-refs ------------------------------------------------
//
// `s.crossRef([a, b])` writes a manifest the engine has to accept and then
// resolve *across* both forms — again the half `hosts/schema` cannot reach
// on its own, since it has no engine.

function pipelineSchema() {
  return s.plugin('gpu', {
    forms: [
      s.form('render-pipeline', { name: s.symbol() }, 'gpu'),
      s.form('compute-pipeline', { name: s.symbol() }, 'gpu'),
      s.form('dispatch', { pipeline: s.crossRef(['render-pipeline', 'compute-pipeline']) }, 'gpu'),
    ],
  });
}

test('a builder-authored target group is a clean manifest', async () => {
  const be = await backend();
  const outcome = be.validate(pipelineSchema().manifest());
  assert.deepEqual(
    outcome.diagnostics.filter((d) => d.severity === 'err'),
    [],
    'the `:target [a b]` vector must load as a target group',
  );
});

test('a name from either target resolves through one slot', async () => {
  const be = await backend();
  const doc =
    '(gpu/render-pipeline :name blit)\n' +
    '(gpu/compute-pipeline :name reduce)\n' +
    '(gpu/dispatch :pipeline blit)\n' +
    '(gpu/dispatch :pipeline reduce)';
  const outcome = be.validate(`${pipelineSchema().manifest()}\n${doc}`);
  assert.deepEqual(
    outcome.diagnostics.filter((d) => d.severity === 'err'),
    [],
  );
});

test('a name defined by two targets in one group collides', async () => {
  const be = await backend();
  const doc = '(gpu/render-pipeline :name same)\n(gpu/compute-pipeline :name same)';
  const outcome = be.validate(`${pipelineSchema().manifest()}\n${doc}`);
  assert.ok(
    outcome.diagnostics.some((d) => d.code === 'duplicate_cross_ref_target'),
    `expected duplicate_cross_ref_target, got ${outcome.diagnostics.map((d) => d.code).join(', ')}`,
  );
});

// --- :multiple-of ----------------------------------------------------------
//
// `s.number().multipleOf(N)` writes a `(numeric-bounds … :multiple-of N)` the
// engine has to accept and then *check* — the half `hosts/schema` cannot
// reach on its own, since it has no engine. Without this the package could
// emit the key and no test would notice it never bit.

function bufferSchema() {
  return s.form(
    'binding',
    {
      offset: s.number().min(0).int().multipleOf(256),
    },
    'gpu',
  );
}

test('a builder-authored :multiple-of is a clean manifest', async () => {
  const be = await backend();
  const outcome = be.validate(bufferSchema().manifest());
  assert.deepEqual(
    outcome.diagnostics.filter((d) => d.severity === 'err'),
    [],
  );
});

test('a builder-authored :multiple-of actually bites', async () => {
  s.use(await backend());
  const Binding = bufferSchema();
  assert.equal(Binding.safeParse('(gpu/binding :offset 512)').success, true);

  const bad = Binding.safeParse('(gpu/binding :offset 250)');
  assert.equal(bad.success, false);
  if (!bad.success) {
    assert.ok(
      bad.error.errors.some((d) => d.code === 'number_not_multiple'),
      `expected number_not_multiple, got ${bad.error.errors.map((d) => d.code).join(', ')}`,
    );
  }

  // The check order the manifest spec fixes: integrality, then range, then
  // divisibility, first failure only. `250.5` fails all three and reports
  // the most basic one.
  const fractional = Binding.safeParse('(gpu/binding :offset 250.5)');
  assert.equal(fractional.success, false);
  if (!fractional.success) {
    assert.ok(fractional.error.errors.some((d) => d.code === 'number_not_integer'));
  }
});
