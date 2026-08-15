// @sjon/schema over the native TypeScript validator. Proves the builder's
// serialized manifest validates identically through a second, non-WASM
// backend, and that `.validate` / `.toDts` work without a value codec.
// The data-materializing methods (`.parse` / `.parseValue`) need
// `toJson` / `fromValue`, which this host doesn't have — asserted below.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { s, SjonValidationError } from '@sjon/schema';
import { nativeBackend } from '../src/SjonSchemaBackend.ts';

s.use(nativeBackend());

function profileSchema() {
  return s.form(
    'profile',
    {
      handle: s.slug(),
      email: s.email(),
      score: s.number().min(0).max(100).optional(),
      nick: s.string().minLen(5).optional(),
    },
    'bounds',
  );
}

const errCodes = (outcome: { diagnostics: readonly { code: string; severity: string }[] }) =>
  outcome.diagnostics.filter((d) => d.severity === 'err').map((d) => d.code);

test('generated manifest is a clean plugin declaration', () => {
  const outcome = profileSchema().validate('');
  assert.deepEqual(errCodes(outcome), []);
});

test('.validate accepts a conforming document', () => {
  const outcome = profileSchema().validate(
    '(bounds/profile :handle "ada" :email "ada@example.com" :score 50)',
  );
  assert.deepEqual(errCodes(outcome), []);
});

test('.validate flags an out-of-range numeric value', () => {
  const outcome = profileSchema().validate(
    '(bounds/profile :handle "ada" :email "ada@example.com" :score 999)',
  );
  assert.ok(errCodes(outcome).includes('number_above_max'));
});

test('.validate flags a too-short string', () => {
  const outcome = profileSchema().validate(
    '(bounds/profile :handle "ada" :email "ada@example.com" :nick "ab")',
  );
  assert.ok(errCodes(outcome).includes('string_too_short'));
});

test('.validate flags a missing required key', () => {
  const outcome = profileSchema().validate('(bounds/profile :handle "ada")');
  assert.ok(errCodes(outcome).includes('missing_required_key'));
});

test('.toDts emits the form interface via the native exporter', () => {
  const dts = profileSchema().toDts();
  assert.match(dts, /export interface Bounds_Profile/);
  assert.match(dts, /\$form: "profile"/);
  assert.match(dts, /\$ns: "bounds"/);
});

test('.parse needs a codec backend (WASM-only) — throws clearly here', () => {
  const Profile = profileSchema();
  assert.throws(
    () => Profile.parse('(bounds/profile :handle "ada" :email "ada@example.com")'),
    (err: unknown) => {
      assert.ok(err instanceof Error);
      assert.ok(!(err instanceof SjonValidationError), 'should not be a validation error');
      assert.match(err.message, /toJson/);
      return true;
    },
  );
});

test('.parseValue needs a codec backend (WASM-only) — throws clearly here', () => {
  const Profile = profileSchema();
  assert.throws(
    () =>
      Profile.parseValue({
        $form: 'profile',
        $ns: 'bounds',
        handle: 'ada',
        email: 'ada@example.com',
      }),
    (err: unknown) => {
      assert.ok(err instanceof Error);
      assert.match(err.message, /fromValue/);
      return true;
    },
  );
});
