// End-to-end: the @sjon/schema fluent builder over the WASM backend.
// Author a form in TS, validate real SJON text + JS objects, and get
// typed data (or SjonValidationError) back — all through sjon.wasm.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import { createWasmBackend } from '../SjonSchemaBackend.ts';
import { s, SjonValidationError } from '@sjon/schema';

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
