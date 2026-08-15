// Conformance invariant: `s.infer<typeof Form>` ≡ `exportSchema(Form.manifest()).tsTypes`.
//
// Two halves, together pinning the equivalence:
//   1. EMIT — the builder's manifest, lowered by the native exporter,
//      reproduces the committed golden `.d.ts` byte-for-byte.
//   2. TYPE — `conformanceTypes.ts` (the phantom inference vs. the emitted
//      interface, bidirectional) compiles under `tsc --noEmit --strict`.
// (1) ∧ (2) ⇒ inference matches the emitted declarations.

import { test } from 'node:test';
import * as assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { s } from '@sjon/schema';
import { nativeBackend } from '../src/SjonSchemaBackend.ts';
import { Profile } from './conformanceFixtures.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const tspRoot = path.resolve(here, '..');
const goldenPath = path.join(here, 'golden', 'bounds.d.ts');
const probePath = path.join(here, 'conformanceTypes.ts');

s.use(nativeBackend());

test('EMIT: builder manifest → exporter .d.ts matches the committed golden', () => {
  const emitted = Profile.toDts();
  const golden = readFileSync(goldenPath, 'utf8');
  assert.equal(
    emitted,
    golden,
    'builder/exporter output drifted from the golden — regenerate test/golden/bounds.d.ts if intended',
  );
});

test('TYPE: s.infer<T> ≡ emitted interface (conformanceTypes.ts compiles)', (t) => {
  // `SJON_TSC` overrides the tsc binary (bracket access —
  // `noPropertyAccessFromIndexSignature` rejects `env.SJON_TSC`). It both
  // lets a caller point at a non-default tsc and makes the skip path
  // testable: `SJON_TSC=/nonexistent node --test …` forces the skip.
  const tscPath = process.env['SJON_TSC'] ?? path.join(tspRoot, 'node_modules', '.bin', 'tsc');
  if (!existsSync(tscPath)) {
    // A silent `return` here reported this as a PASS on toolchains without
    // dev deps — the TYPE half was never verified yet nothing said so. Skip
    // loudly instead: `# SKIP` in the TAP stream, with the path in a
    // diagnostic, so an absent tsc is visible rather than a false green.
    t.diagnostic(`tsc not found at ${tscPath} — TYPE half not verified (set SJON_TSC to override)`);
    t.skip('tsc unavailable');
    return;
  }

  const tsc = spawnSync(
    tscPath,
    [
      '--noEmit',
      '--strict',
      '--exactOptionalPropertyTypes',
      '--target',
      'es2022',
      '--module',
      'esnext',
      '--moduleResolution',
      'bundler',
      '--allowImportingTsExtensions',
      '--skipLibCheck',
      probePath,
    ],
    { encoding: 'utf8', cwd: tspRoot },
  );
  if (tsc.status !== 0) {
    assert.fail(
      'conformance probe failed to type-check — s.infer drifted from the emitted .d.ts:\n' +
        `stdout:\n${tsc.stdout}\nstderr:\n${tsc.stderr}`,
    );
  }
});
