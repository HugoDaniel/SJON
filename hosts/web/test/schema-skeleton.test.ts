// Starter skeletons through the real Web backend. The emitted text is ordinary
// SJON: a hole is accepted only when the *run* opts into `heldSymbol`, and the
// no-option control is what keeps held acceptance from meaning "validation was
// weakened". Filling the holes produces the ordinary typed value, and a hole
// still does not open a closed form to undeclared keys.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import { createWasmBackend } from '../SjonSchemaBackend.ts';
import { s } from '@sjon-lang/schema';
import type { BackendDiagnostic, ValidateBackend } from '@sjon-lang/schema';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

// The measured form: required `name`, defaulted `count`, optional `enabled`.
const Starter = s.form(
  'starter',
  {
    name: s.string(),
    count: s.number().default(2),
    enabled: s.boolean().optional(),
  },
  'studio',
);

interface Backends {
  readonly held: ValidateBackend;
  readonly plain: ValidateBackend;
}

let cached: Backends | null = null;
async function backends(): Promise<Backends> {
  if (cached === null) {
    const host = await SjonHost.load(wasmPath);
    cached = {
      held: createWasmBackend(host, { heldSymbol: '_' }),
      plain: createWasmBackend(host),
    };
  }
  return cached;
}

function errs(diagnostics: readonly BackendDiagnostic[]): BackendDiagnostic[] {
  return diagnostics.filter((d) => d.severity === 'err');
}

test('the skeleton is clean when the run opts into the held symbol', async () => {
  const { held } = await backends();
  const outcome = Starter.validate(Starter.skeleton(), { backend: held });
  assert.deepEqual(
    errs(outcome.diagnostics),
    [],
    `unexpected validation errors:\n${JSON.stringify(errs(outcome.diagnostics), null, 2)}`,
  );
});

test('without heldSymbol the same skeleton reports both non-default holes', async () => {
  const { plain } = await backends();
  const outcome = Starter.validate(Starter.skeleton(), { backend: plain });
  const errors = errs(outcome.diagnostics);
  assert.deepEqual(
    errors.map((d) => d.code),
    ['wrong_underlying', 'wrong_underlying'],
    `the no-option control must stay red on both holes:\n${JSON.stringify(errors, null, 2)}`,
  );
  assert.deepEqual(
    errors.map((d) => d.path),
    [
      ['starter', 'name'],
      ['starter', 'enabled'],
    ],
  );
});

test('filling the holes is clean and .parse returns the ordinary typed value', async () => {
  const { plain } = await backends();
  const filled = Starter.toSjon({ name: 'demo', enabled: true });
  assert.equal(filled, '(studio/starter :name "demo" :count 2 :enabled true)');

  const outcome = Starter.validate(filled, { backend: plain });
  assert.deepEqual(
    errs(outcome.diagnostics),
    [],
    `unexpected validation errors:\n${JSON.stringify(errs(outcome.diagnostics), null, 2)}`,
  );

  const data = Starter.parse(filled, { backend: plain });
  assert.equal(data.$form, 'starter');
  assert.equal(data.$ns, 'studio');
  assert.equal(data.name, 'demo');
  assert.equal(data.count, 2);
  assert.equal(data.enabled, true);
});

test('a hole does not open the closed skeleton: an unknown key still reports', async () => {
  const { held } = await backends();
  const skeleton = Starter.skeleton();
  const tampered = `${skeleton.slice(0, -1)} :bogus 1)`;
  const outcome = Starter.validate(tampered, { backend: held });
  const unknown = errs(outcome.diagnostics).filter((d) => d.code === 'unknown_key');
  assert.equal(
    unknown.length,
    1,
    `expected exactly one unknown_key even in the held run, got ${JSON.stringify(errs(outcome.diagnostics), null, 2)}`,
  );
  assert.deepEqual(unknown[0]!.path, ['starter', 'bogus']);
});
