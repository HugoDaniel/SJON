// `tsc --noEmit --strict` compile check for the Zig CLI's emitted
// `.d.ts`. Proves the generated declarations are well-typed and that
// a hand-authored consumer using them passes strict-mode typing.
//
// Test flow per fixture:
//   1. Invoke `./zig-out/bin/sjon export-schema <manifest> --target=typescript --output=<tmpdir>`.
//   2. Write a small consumer.ts file under `<tmpdir>` that imports
//      the generated types and constructs a minimal valid value.
//   3. Spawn `tsc --noEmit --strict --target es2022 --module esnext
//      --moduleResolution bundler <tmpdir>/consumer.ts`.
//   4. Assert exit code 0; dump stderr on failure.
//
// The Zig CLI is invoked (not the TS-parity exporter) — this test
// pins the CLI's emitted bytes, not the parity port. The parity port
// has its own structural assertions in `schemaExport.test.ts`.

import { test } from 'node:test';
import * as assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, existsSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const cliPath = path.join(root, 'zig-out/bin/sjon');
const examplesDir = path.join(root, 'examples/plugins');

interface CompileFixture {
  readonly plugin: string;
  readonly manifestPath: string;
  /** TS expression to construct a minimal valid instance of the plugin's primary form. */
  readonly consumer: string;
}

// Hand-authored consumer snippets per fixture. The plugin-author
// guarantees these match the schema; tsc validates the .d.ts.
//
// New fixtures land in this list only when their `example.sjon` lands
// in §F (auto-discovery would require parsing the example, which is
// the round-trip test's job).
const FIXTURES: readonly CompileFixture[] = [
  {
    plugin: 'shapes',
    manifestPath: path.join(examplesDir, 'shapes.zig'),
    // shapes is the static plugin — the CLI's `export-schema` path
    // can't load it directly (no plugin.sjon). Skipped at runtime.
    consumer: '',
  },
  {
    plugin: 'bounds',
    manifestPath: path.join(examplesDir, 'bounds/plugin.sjon'),
    consumer: `
import type { Bounds_Profile } from "./bounds";

const p: Bounds_Profile = {
  $form: "profile",
  $ns: "bounds",
  handle: "ada",
  email: "ada@example.com",
  uuid: "11111111-1111-4111-8111-111111111111",
};
void p;
`.trim(),
  },
  {
    plugin: 'local-forms',
    manifestPath: path.join(examplesDir, 'local-forms/plugin.sjon'),
    // Exercises the inline form_locals union on canvas.:shape: a local
    // circle branch (required :r), a nested local (group → child → dot), and
    // the trailing open generic branch (any global form, e.g. line). All
    // three must type-check against the emitted union.
    consumer: `
import type { LocalForms_Canvas } from "./local-forms";

const local: LocalForms_Canvas = {
  $form: "canvas",
  $ns: "local-forms",
  shape: { $form: "circle", r: 12 },
};
void local;

const nested: LocalForms_Canvas = {
  $form: "canvas",
  $ns: "local-forms",
  shape: { $form: "group", child: { $form: "dot" } },
};
void nested;

const fallback: LocalForms_Canvas = {
  $form: "canvas",
  $ns: "local-forms",
  shape: { $form: "line" },
};
void fallback;
`.trim(),
  },
  {
    plugin: 'gpu',
    manifestPath: path.join(examplesDir, 'gpu/plugin.sjon'),
    // Value-kind refinements: a variable-arity vector (`position` widens to
    // Array<number>) plus a u16 repr channel (`tint?: U16`). The sibling
    // `draw` form carries the f32/u32 repr and unit-reject slots, so the
    // whole branded .d.ts must type-check even though the consumer builds a
    // vertex via its single required, non-branded slot.
    consumer: `
import type { Gpu_Vertex } from "./gpu";

const v: Gpu_Vertex = {
  $form: "vertex",
  $ns: "gpu",
  position: [0, 1, 0.5],
};
void v;
`.trim(),
  },
  {
    plugin: 'scalar-or-ref',
    manifestPath: path.join(examplesDir, 'scalar-or-ref/plugin.sjon'),
    // scalar-or-ref desugars to `union [dim-value symbol]`; each axis slot is
    // `number | Symbol_`. A literal count satisfies the scalar (number) arm.
    consumer: `
import type { ScalarOrRef_Dispatch } from "./scalar-or-ref";

const d: ScalarOrRef_Dispatch = {
  $form: "dispatch",
  $ns: "scalar-or-ref",
  x: 64,
  y: 64,
};
void d;
`.trim(),
  },
];

function ensureCli() {
  if (!existsSync(cliPath)) {
    throw new Error(`expected sjon CLI at ${cliPath}; run \`zig build cli\` first`);
  }
}

function findTsc(): string | null {
  // Prefer the typescript-parity host's local `tsc`. Skip the test
  // gracefully when typescript isn't installed (e.g. fresh checkout).
  const local = path.join(root, 'hosts/typescript-parity/node_modules/.bin/tsc');
  if (existsSync(local)) return local;
  return null;
}

for (const fixture of FIXTURES) {
  // Static-plugin fixtures (no plugin.sjon) get skipped; the CLI
  // can only export from a SJON source.
  if (!fixture.manifestPath.endsWith('.sjon') || !existsSync(fixture.manifestPath)) continue;

  test(`schema-export compile: ${fixture.plugin} (.d.ts passes tsc --strict)`, () => {
    ensureCli();
    const tscPath = findTsc();
    if (!tscPath) {
      // Skip silently when tsc isn't available — no environment to
      // run the check, but the test shouldn't fail in that state.
      return;
    }

    const dir = mkdtempSync(path.join(tmpdir(), `sjon-tsc-${fixture.plugin}-`));
    const cli = spawnSync(
      cliPath,
      ['export-schema', fixture.manifestPath, '--target=typescript', `--output=${dir}`],
      { encoding: 'utf8' },
    );
    if (cli.status !== 0) {
      assert.fail(
        `sjon export-schema failed (status=${cli.status}):\nstdout: ${cli.stdout}\nstderr: ${cli.stderr}`,
      );
    }

    // The CLI emits `<dir>/types.d.ts` for aggregated layout. Rename
    // it to `<plugin>.d.ts` so `import "./<plugin>"` resolves.
    const typesPath = path.join(dir, 'types.d.ts');
    assert.ok(existsSync(typesPath), `${typesPath} not produced`);
    const renamedPath = path.join(dir, `${fixture.plugin}.d.ts`);
    writeFileSync(renamedPath, readFileSync(typesPath, 'utf8'));

    const consumerPath = path.join(dir, 'consumer.ts');
    writeFileSync(consumerPath, fixture.consumer + '\n');

    const tsc = spawnSync(
      tscPath,
      [
        '--noEmit',
        '--strict',
        '--target',
        'es2022',
        '--module',
        'esnext',
        '--moduleResolution',
        'bundler',
        '--allowImportingTsExtensions',
        consumerPath,
      ],
      { encoding: 'utf8' },
    );
    if (tsc.status !== 0) {
      assert.fail(
        `tsc --noEmit failed for ${fixture.plugin}:\n` +
          `stdout:\n${tsc.stdout}\n` +
          `stderr:\n${tsc.stderr}\n` +
          `.d.ts contents:\n${readFileSync(renamedPath, 'utf8')}\n` +
          `consumer.ts contents:\n${fixture.consumer}`,
      );
    }
  });
}
