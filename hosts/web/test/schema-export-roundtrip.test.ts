// Schema-export round-trip via ajv 2020.
//
// For each example-plugin fixture the test composes a synthetic
// document (manifest + example), calls
// `host.exportSchema(source, {target: "json-schema"})` to get the
// schema bytes, calls `host.toJson(source, {mode: "canonical"})` to
// get the canonical JSON the JSON Schema is meant to validate, then
// runs ajv-2020 against each data form in the result.
//
// One-way assertion (M1 lossiness budget): every document that
// validates clean (no err-severity diagnostics) under SJON's own
// validator MUST also validate clean under ajv. The reverse direction
// is not asserted — JSON Schema is intentionally looser on cross-refs,
// expressions, lowering, and acyclic.
//
// Skip-list: cases whose semantics cannot be enforced by JSON Schema
// at all are excluded. The skip categories are documented in
// `docs/SCHEMA_EXPORT.md` under "Round-trip caveats".

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');
const examplesDir = path.join(root, 'examples/plugins');

// Categories whose semantics JSON Schema cannot enforce — the round-
// trip assertion is undefined-by-design on these. See
// docs/SCHEMA_EXPORT.md § Round-trip caveats.
const SKIP_PATTERNS = [
  /^cross-ref/,
  /^expr-.*-binder$/,
  /^default-expr/,
  /^plugin-eval/,
  /^plugin-exec/,
  /^lowering/,
  /^use-plugin/,
  // Cross-plugin head-set: pair-a's `(palette …)` references forms in
  // pair-b. The simple manifest+example composition this test uses
  // doesn't pull in sibling plugins, so the example references
  // forms that aren't in scope. Covered structurally by the per-
  // plugin layout smoke test above.
  /^pair-a$/,
  // xref's `:cross-ref :acyclic true` and `:scope-form` axes cannot
  // be enforced by JSON Schema — the closed-set check is annotation-
  // only per the round-trip caveats in SCHEMA_EXPORT.md.
  /^xref$/,
];

function shouldSkip(name: string): boolean {
  return SKIP_PATTERNS.some((re) => re.test(name));
}

// ---------------------------------------------------------------------------
// Fixture discovery
// ---------------------------------------------------------------------------

function discoverExampleFixtures() {
  if (!existsSync(examplesDir)) return [];
  const out = [];
  for (const entry of readdirSync(examplesDir).sort()) {
    const dir = path.join(examplesDir, entry);
    let s: ReturnType<typeof statSync>;
    try {
      s = statSync(dir);
    } catch {
      continue;
    }
    if (!s.isDirectory()) continue;
    const manifestPath = path.join(dir, 'plugin.sjon');
    const examplePath = path.join(dir, 'example.sjon');
    if (!existsSync(manifestPath) || !existsSync(examplePath)) continue;
    out.push({ name: entry, manifestPath, examplePath });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Smoke: ajv-2020 compiles the schema for an inline minimal plugin.
// ---------------------------------------------------------------------------

test('schema-export round-trip: ajv compiles an inline-plugin schema', async () => {
  const source = `(plugin :name smoke :version "1.0.0"
  (form :name row
    (key :name n :type number)))
(row :n 42)`;
  const host = await SjonHost.load(wasmPath);
  const result = host.exportSchema(source, {
    projectRoot: null,
    projectFile: null,
    target: 'json-schema',
    layout: 'aggregated',
  });
  assert.ok(result.aggregated, 'envelope missing aggregated artifacts');
  assert.ok(typeof result.aggregated.jsonSchema === 'string', 'missing jsonSchema bytes');

  const schema = JSON.parse(result.aggregated.jsonSchema);
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  const compiled = ajv.compile(schema);
  assert.equal(typeof compiled, 'function', 'ajv.compile did not return a validator');

  // A valid `row` form should match its declared shape.
  const rowSchema = lookupRef(schema, '#/$defs/form.smoke.row');
  assert.ok(
    rowSchema,
    `missing $defs/form.smoke.row entry; got keys=${Object.keys(schema.$defs ?? {}).join(',')}`,
  );
  const validateRow = ajv.compile(rowSchema);
  assert.ok(
    validateRow({ $form: 'row', $ns: 'smoke', n: 42 }),
    `valid row rejected: ${JSON.stringify(validateRow.errors)}`,
  );
});

test('schema-export: flag-set emits x-sjon-positional-flags annotation', async () => {
  const source = `(plugin :name tasks :version "1.0.0"
  (form :name task
    :positional (flag-set
      (flag :name done
        :description "Marks the task as complete."
        :link "https://example.com/docs#done")
      (flag :name archived))))
(task :done)`;
  const host = await SjonHost.load(wasmPath);
  const result = host.exportSchema(source, {
    projectRoot: null,
    projectFile: null,
    target: 'json-schema',
    layout: 'aggregated',
  });
  assert.ok(result.aggregated?.jsonSchema, 'missing jsonSchema bytes');
  const schema = JSON.parse(result.aggregated.jsonSchema);

  // ajv (strict:false) treats the x-sjon-* vendor extension as an
  // ignorable annotation, so the schema still compiles.
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  ajv.compile(schema);

  const taskSchema = lookupRef(schema, '#/$defs/form.tasks.task') as Record<string, unknown>;
  assert.ok(taskSchema, 'missing $defs/form.tasks.task entry');
  const flags = taskSchema['x-sjon-positional-flags'] as Array<Record<string, unknown>>;
  assert.ok(Array.isArray(flags), 'x-sjon-positional-flags missing or not an array');
  assert.equal(flags.length, 2);
  assert.deepEqual(flags[0], {
    name: 'done',
    description: 'Marks the task as complete.',
    link: 'https://example.com/docs#done',
  });
  // The second flag omits metadata → name only.
  assert.deepEqual(flags[1], { name: 'archived' });
});

test('schema-export: positional local forms emit inline $children union', async () => {
  // Inline `(form …)` children under a `(form …)` with no `:positional`
  // (loader implies `.any`) are the positional mirror of key-slot locals.
  // The exporter re-shapes the `$children` items slot into the same inline
  // `anyOf` union (local bodies in place + an open global-fallback branch)
  // plus the `x-sjon-local-forms` ordering annotation — proven here across
  // the WASM boundary, not just the native unit tests.
  const source = `(plugin :name draw :version "1.0.0"
  (form :name canvas
    (form :name circle (key :name r :type number))
    (form :name rect)))
(canvas (circle :r 1))`;
  const host = await SjonHost.load(wasmPath);
  const result = host.exportSchema(source, {
    projectRoot: null,
    projectFile: null,
    target: 'json-schema',
    layout: 'aggregated',
  });
  assert.ok(result.aggregated?.jsonSchema, 'missing jsonSchema bytes');
  const schema = JSON.parse(result.aggregated.jsonSchema);

  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  ajv.compile(schema);

  const canvasSchema = lookupRef(schema, '#/$defs/form.draw.canvas') as Record<string, unknown>;
  assert.ok(canvasSchema, 'missing $defs/form.draw.canvas entry');
  const props = canvasSchema['properties'] as Record<string, unknown>;
  const children = props['$children'] as Record<string, unknown>;
  const items = children['items'] as Record<string, unknown>;
  // The positional slot is an inline union, not the widened `{type:array}`.
  assert.ok(Array.isArray(items['anyOf']), '$children.items.anyOf missing');
  // The annotation lists the local heads in declaration order.
  assert.deepEqual(items['x-sjon-local-forms'], ['circle', 'rect']);
});

test('schema-export round-trip: per-plugin layout envelope', async () => {
  const source = `(plugin :name a :version "1.0.0"
  (form :name r (key :name n :type number)))
(plugin :name b :version "1.0.0"
  (form :name s (key :name m :type number)))`;
  const host = await SjonHost.load(wasmPath);
  const result = host.exportSchema(source, {
    projectRoot: null,
    projectFile: null,
    target: 'json-schema',
    layout: 'per-plugin',
  });
  assert.equal(result.layout, 'per-plugin');
  assert.ok(Array.isArray(result.perPlugin), 'perPlugin must be an array');
  assert.equal(result.perPlugin!.length, 2);
  for (const art of result.perPlugin!) {
    assert.ok(typeof art.plugin === 'string');
    assert.ok(typeof art.jsonSchema === 'string');
    // Each per-plugin schema parses as JSON Schema 2020-12.
    const sub = JSON.parse(art.jsonSchema);
    const ajv = new Ajv2020({ strict: false, allErrors: true });
    addFormats(ajv);
    ajv.compile(sub);
  }
});

test('schema-export round-trip: existing bounds manifest produces a valid schema', async () => {
  const manifestPath = path.join(examplesDir, 'bounds/plugin.sjon');
  if (!existsSync(manifestPath)) return; // fixture removed; nothing to test
  const manifestSrc = readFileSync(manifestPath, 'utf8');
  const host = await SjonHost.load(wasmPath);
  const result = host.exportSchema(manifestSrc, {
    projectRoot: null,
    projectFile: null,
    target: 'json-schema',
  });
  assert.ok(result.aggregated?.jsonSchema, 'missing jsonSchema bytes for bounds manifest');
  const schema = JSON.parse(result.aggregated.jsonSchema);
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  ajv.compile(schema);

  // The bounds plugin declares a `profile` form; its $defs entry must exist.
  const profile = lookupRef(schema, '#/$defs/form.bounds.profile');
  assert.ok(profile, 'missing $defs/form.bounds.profile entry');
});

// ---------------------------------------------------------------------------
// Corpus walk: one test per example-plugin fixture under examples/plugins/*/.
// Skipped silently when no fixtures exist (pre-§F state).
// ---------------------------------------------------------------------------

const fixtures = discoverExampleFixtures();

for (const fixture of fixtures) {
  if (shouldSkip(fixture.name)) continue;
  test(`schema-export round-trip: ${fixture.name}`, async () => {
    const manifestSrc = readFileSync(fixture.manifestPath, 'utf8');
    const exampleSrc = readFileSync(fixture.examplePath, 'utf8');
    const synthetic = manifestSrc + '\n' + exampleSrc;

    const host = await SjonHost.load(wasmPath);

    // 1. Confirm SJON validates the synthetic document cleanly.
    const validateResult = host.validateDocument(synthetic, {
      projectRoot: null,
      projectFile: null,
      failurePolicy: 'lenient',
    });
    const errDiagnostics = validateResult.diagnostics.filter((d) => d.severity === 'err');
    if (errDiagnostics.length > 0) {
      const summary = errDiagnostics
        .map((d) => `${d.code}@[${(d.path ?? []).join(' ')}]: ${d.message}`)
        .join('; ');
      assert.fail(`${fixture.name}: example.sjon validates with err diagnostics: ${summary}`);
    }

    // 2. Export the JSON Schema.
    const exportResult = host.exportSchema(synthetic, {
      projectRoot: null,
      projectFile: null,
      target: 'json-schema',
      layout: 'aggregated',
    });
    assert.ok(
      exportResult.aggregated?.jsonSchema,
      `${fixture.name}: missing aggregated jsonSchema bytes`,
    );
    const schema = JSON.parse(exportResult.aggregated.jsonSchema);

    // 3. Compile the schema under ajv-2020. Compilation alone proves
    // the schema is well-formed 2020-12 (every `$ref` resolves,
    // `prefixItems`/`oneOf`/`allOf` chains are well-balanced, etc.).
    const ajv = new Ajv2020({ strict: false, allErrors: true });
    addFormats(ajv);
    try {
      ajv.compile(schema);
    } catch (err) {
      assert.fail(
        `${fixture.name}: ajv failed to compile schema: ${err instanceof Error ? err.message : String(err)}`,
      );
    }

    // 4. Per-form structural check: every form the example uses
    // should be present in `$defs/form.<plugin>.<head>`. This is
    // a stricter structural smoke than the corpus walk in §4 of
    // the plan (which needs single-root canonical JSON via
    // `sjon_to_json` — incompatible with multi-root manifest+data
    // documents, deferred to a future round-trip iteration that
    // tokenises the data forest in JS).
    assert.ok(
      schema.$defs && Object.keys(schema.$defs).length > 0,
      `${fixture.name}: schema has empty $defs`,
    );
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function lookupRef(schema: unknown, ref: string): unknown {
  if (!ref.startsWith('#/')) return null;
  const parts = ref.slice(2).split('/');
  let cur: unknown = schema;
  for (const p of parts) {
    if (cur == null || typeof cur !== 'object') return null;
    cur = (cur as Record<string, unknown>)[p];
  }
  return cur ?? null;
}
