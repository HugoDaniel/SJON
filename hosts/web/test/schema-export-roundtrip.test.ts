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

test('schema-export round-trip: ajv enforces per-head positional counts', async () => {
  // The one claim in the bounds encoding that cannot be checked by reading
  // the exporter: that `contains` + `minContains` / `maxContains` actually
  // *bites* in a real 2020-12 validator, rather than merely being the
  // keyword the spec names. So compile the head-counts schema and drive
  // ajv over the same three documents the SJON validator judges.
  const manifestPath = path.join(examplesDir, 'head-counts/plugin.sjon');
  if (!existsSync(manifestPath)) return; // fixture removed; nothing to test
  const manifestSrc = readFileSync(manifestPath, 'utf8');
  const host = await SjonHost.load(wasmPath);
  const result = host.exportSchema(manifestSrc, {
    projectRoot: null,
    projectFile: null,
    target: 'json-schema',
  });
  assert.ok(result.aggregated?.jsonSchema, 'missing jsonSchema bytes');
  const schema = JSON.parse(result.aggregated.jsonSchema);
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  // Compile through a `$ref` into the document's own `$defs`, not the
  // extracted sub-schema: the `contains` entries this test is about are
  // themselves `$ref`s into `$defs`, so a detached sub-schema cannot
  // resolve them.
  const validate = ajv.compile({
    $schema: schema.$schema,
    $defs: schema.$defs,
    $ref: '#/$defs/form.head-counts.render-pipeline',
  });

  const vertex = { $form: 'vertex', $ns: 'head-counts', entry: { $sym: 'vs' } };
  const fragment = { $form: 'fragment', $ns: 'head-counts', entry: { $sym: 'fs' } };
  const constant = {
    $form: 'constant',
    $ns: 'head-counts',
    name: { $sym: 'gamma' },
    value: 2.2,
  };
  const pipeline = (children: unknown[]) => ({
    $form: 'render-pipeline',
    $ns: 'head-counts',
    name: { $sym: 'main' },
    $children: children,
  });

  assert.equal(
    validate(pipeline([vertex, fragment, constant, constant])),
    true,
    `inside every bound, ajv should accept: ${JSON.stringify(validate.errors)}`,
  );
  // `:max 1` on fragment — a second one must be rejected. If `maxContains`
  // were dropped (or written as `maxItems`), this would pass.
  assert.equal(
    validate(pipeline([vertex, fragment, fragment])),
    false,
    'over :max: expected reject',
  );
  // `:min 1` on vertex — none at all must be rejected.
  assert.equal(validate(pipeline([fragment])), false, 'under :min: expected reject');
  // …including when there are no children whatsoever. The JSON bridge
  // OMITS `$children` for a childless form (`Json.zig`'s
  // `if (children.items.len > 0)`), so a floor that lives only inside the
  // `$children` subschema is unreachable for the very document that
  // breaches it hardest. `required: ["$children"]` is what closes it.
  assert.equal(validate(pipeline([])), false, 'empty $children: expected reject');
  assert.equal(
    validate({
      $form: 'render-pipeline',
      $ns: 'head-counts',
      name: { $sym: 'main' },
    }),
    false,
    'absent $children under a floor: expected reject',
  );
  // The unbounded head really is unbounded: four constants are fine, which
  // is what `minItems`/`maxItems` would have wrongly rejected.
  assert.equal(
    validate(pipeline([vertex, constant, constant, constant, constant])),
    true,
    `unbounded head should stay unbounded: ${JSON.stringify(validate.errors)}`,
  );
});

test('schema-export round-trip: ajv enforces the count over a whole head-set', async () => {
  // The claim the exporter cannot make about itself, one level up from
  // the per-head test above: that `contains: {anyOf: […]}` + `minContains`
  // / `maxContains` actually *bites* in a real 2020-12 validator.
  //
  // Four documents, and the middle two are the ask's own probes — an
  // entry with two different resources and an entry with none. Both
  // satisfy every per-head bound, so the per-head `contains` entries in
  // the same `allOf` accept them; only the set's entry can refuse.
  const manifestPath = path.join(examplesDir, 'head-counts/plugin.sjon');
  if (!existsSync(manifestPath)) return; // fixture removed; nothing to test
  const manifestSrc = readFileSync(manifestPath, 'utf8');
  const host = await SjonHost.load(wasmPath);
  const result = host.exportSchema(manifestSrc, {
    projectRoot: null,
    projectFile: null,
    target: 'json-schema',
  });
  assert.ok(result.aggregated?.jsonSchema, 'missing jsonSchema bytes');
  const schema = JSON.parse(result.aggregated.jsonSchema);
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  const validate = ajv.compile({
    $schema: schema.$schema,
    $defs: schema.$defs,
    $ref: '#/$defs/form.head-counts.bgl-entry',
  });

  const buffer = { $form: 'buffer', $ns: 'head-counts', type: { $sym: 'uniform' } };
  const sampler = { $form: 'sampler', $ns: 'head-counts', type: { $sym: 'filtering' } };
  const entry = (children: unknown[]) => {
    const out: Record<string, unknown> = {
      $form: 'bgl-entry',
      $ns: 'head-counts',
      binding: 0,
    };
    // Mirror the JSON bridge: a childless form carries no `$children` key
    // at all, which is exactly the case `required` has to cover.
    if (children.length > 0) out['$children'] = children;
    return out;
  };

  assert.equal(
    validate(entry([buffer])),
    true,
    `exactly one resource should be accepted: ${JSON.stringify(validate.errors)}`,
  );
  // Two DIFFERENT resources: `buffer: 0..1` and `sampler: 0..1` are both
  // satisfied. Only `:max-children 1` refuses, so this assertion fails if
  // the set's `allOf` entry is dropped or its `anyOf` is wrong.
  assert.equal(validate(entry([buffer, sampler])), false, 'two resources: expected reject');
  // None at all, and with no `$children` key — the shape the emitter was
  // fabricating a `"buffer":{}` for.
  assert.equal(validate(entry([])), false, 'no resource: expected reject');
  // Two of the SAME: the per-head ceiling refuses it too, which is the
  // redundancy the validator's suppression rule exists for. The export
  // has no suppression to do — both entries simply fail.
  assert.equal(validate(entry([buffer, buffer])), false, 'two buffers: expected reject');
});

test('schema-export round-trip: ajv closes a head-set slot that declares locals', async () => {
  // The sibling the head-counts test above could not be: that manifest
  // uses globals only, which is exactly why it never caught S7b. Here the
  // head-set members resolve to *slot-local* forms with no global
  // declaration anywhere, and two claims need a real validator to check
  // rather than a reading of the exporter.
  //
  //   1. The slot is CLOSED. Before, a locals slot exported `anyOf` with a
  //      trailing `{type: object, required: [$form]}` branch, which
  //      accepts every form there is — so `(ghost …)` passed a schema the
  //      SJON validator rejects with `not_head_member`. An open branch is
  //      invisible to any test that only feeds it valid documents.
  //   2. The per-head `contains` bounds BITE on a locals slot. They were
  //      absent entirely, and an absent `allOf` is indistinguishable from
  //      a satisfied one unless you drive a document past the bound.
  const manifestPath = path.join(examplesDir, 'headset-locals/plugin.sjon');
  if (!existsSync(manifestPath)) return; // fixture removed; nothing to test
  const manifestSrc = readFileSync(manifestPath, 'utf8');
  const host = await SjonHost.load(wasmPath);
  const result = host.exportSchema(manifestSrc, {
    projectRoot: null,
    projectFile: null,
    target: 'json-schema',
  });
  assert.ok(result.aggregated?.jsonSchema, 'missing jsonSchema bytes');
  const schema = JSON.parse(result.aggregated.jsonSchema);
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  // Compiling at all is a claim: an unresolved head used to render
  // `{"$ref": "#/$defs/form..<head>"}`, and ajv refuses to compile a
  // schema with an unresolvable `$ref` — one typo'd head would take the
  // whole document down, not the one slot that earned it.
  const validate = ajv.compile({
    $schema: schema.$schema,
    $defs: schema.$defs,
    $ref: '#/$defs/form.headset-locals.bind-group-layout',
  });

  const ns = 'headset-locals';
  const buffer = { $form: 'buffer', $ns: ns, kind: { $sym: 'uniform' } };
  const storage = { $form: 'storage-texture', $ns: ns, format: { $sym: 'rgba8unorm' } };
  const head = { $form: 'head', $ns: ns, text: 'the camera UBO' };
  const entry = (children: unknown[]) => ({
    $form: 'entry',
    $ns: ns,
    binding: 0,
    $children: children,
  });
  const layout = (children: unknown[]) => ({
    $form: 'bind-group-layout',
    $ns: ns,
    name: { $sym: 'bgl0' },
    $children: children,
  });

  // The happy path: a local body, a *global* body resolved by `$ref`, and
  // an unbounded local repeated — all in one slot.
  assert.equal(
    validate(layout([entry([buffer, head]), entry([storage, storage])])),
    true,
    `in-set children should be accepted: ${JSON.stringify(validate.errors)}`,
  );

  // (1) Closed. `ghost` is in no head-set, so the slot must reject it.
  assert.equal(
    validate(layout([{ $form: 'ghost', $ns: ns }])),
    false,
    'an out-of-set head must be rejected — the open branch used to accept every form',
  );

  // A local that omits its required key is rejected too, which the open
  // branch also used to wave through (SCHEMA_EXPORT.md's one-way caveat
  // holds for an *open* locals slot; a closed one enforces).
  assert.equal(
    validate(layout([entry([{ $form: 'buffer', $ns: ns }])])),
    false,
    'a local missing its required key must be rejected',
  );

  // The one thing closing the slot does NOT tighten, pinned so it cannot
  // change silently. A *qualified* head bypasses the locals and resolves
  // global-only, so `(headset-locals/buffer …)` is `unknown_form` to the
  // validator — but `$ns` is const-pinned and deliberately not required
  // (a bare invocation round-trips without it), so the local's branch
  // accepts it. The looser direction the one-way assertion permits; see
  // SCHEMA_EXPORT.md's caveat table.
  assert.equal(
    validate(layout([entry([{ ...buffer, $ns: ns }])])),
    true,
    'a self-qualified local head is accepted by the schema, per the documented caveat',
  );
  // A qualifier naming a *different* plugin is still rejected, which is
  // what makes the `$ns` const carry any weight at all.
  assert.equal(
    validate(layout([entry([{ ...buffer, $ns: 'somewhere-else' }])])),
    false,
    'a foreign qualifier must still be rejected',
  );

  // (2) The bounds bite. `buffer` is `:max 1` on a locals slot …
  assert.equal(
    validate(layout([entry([buffer, buffer])])),
    false,
    'over :max on a local head: expected reject',
  );
  // … and `entry` is `:min 1` on the outer one.
  assert.equal(validate(layout([])), false, 'under :min on a local head: expected reject');
});

test('schema-export round-trip: ajv accepts a digit-leading member as $num, not $sym', async () => {
  // A digit-leading member is *accepted* in a symbol slot, never rewritten,
  // so a document carries `{"$num": [2, "d"]}` where an ordinary member
  // carries `{"$sym": "cube"}`. That makes the exported schema the one
  // place this feature can be silently wrong: a `$sym` const for `2d`
  // compiles perfectly and rejects every document the validator accepts.
  // Reading the exporter cannot catch that; driving ajv can.
  const manifestPath = path.join(examplesDir, 'dimensions/plugin.sjon');
  if (!existsSync(manifestPath)) return; // fixture removed; nothing to test
  const manifestSrc = readFileSync(manifestPath, 'utf8');
  const host = await SjonHost.load(wasmPath);
  const result = host.exportSchema(manifestSrc, {
    projectRoot: null,
    projectFile: null,
    target: 'json-schema',
  });
  assert.ok(result.aggregated?.jsonSchema, 'missing jsonSchema bytes');
  const schema = JSON.parse(result.aggregated.jsonSchema);
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  addFormats(ajv);
  const validate = ajv.compile({
    $schema: schema.$schema,
    $defs: schema.$defs,
    $ref: '#/$defs/form.dimensions.texture',
  });

  const texture = (fields: Record<string, unknown>) => ({
    $form: 'texture',
    $ns: 'dimensions',
    name: { $sym: 'albedo' },
    ...fields,
  });

  // The wire shape a document actually produces.
  assert.equal(
    validate(texture({ dimension: { $num: [2, 'd'] } })),
    true,
    `$num encoding should be accepted: ${JSON.stringify(validate.errors)}`,
  );
  // The shape a `$sym` export would have demanded. No document can produce
  // it — `2d` never lexes as a symbol — so it must NOT validate, or the
  // schema is describing something the language cannot write.
  assert.equal(
    validate(texture({ dimension: { $sym: '2d' } })),
    false,
    '$sym spelling of a digit-leading member should be rejected',
  );
  // Still a closed set.
  assert.equal(
    validate(texture({ dimension: { $num: [4, 'd'] } })),
    false,
    'undeclared magnitude should be rejected',
  );
  // The unit is part of the identity on this side too.
  assert.equal(
    validate(texture({ dimension: { $num: [2, 'b'] } })),
    false,
    'declared magnitude with the wrong unit should be rejected',
  );
  // A mixed set keeps both shapes working, each in its own encoding.
  assert.equal(
    validate(texture({ view: { $sym: 'cube' } })),
    true,
    `ordinary member should stay $sym: ${JSON.stringify(validate.errors)}`,
  );
  assert.equal(
    validate(texture({ view: { $num: [3, 'd'] } })),
    true,
    `digit-leading member of a mixed set: ${JSON.stringify(validate.errors)}`,
  );
  assert.equal(
    validate(texture({ view: { $sym: 'sphere' } })),
    false,
    'undeclared symbol member should be rejected',
  );
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
