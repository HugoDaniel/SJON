// Schema-export structural tests — TS-parity exporter end-to-end.
//
// Exercises the native lower → emit pipeline against a handful of
// minimal inline plugins and against the M3 `bounds` fixture (which
// the existing TS-parity loader already understands). Asserts the
// JSON Schema output is well-formed 2020-12, the `.d.ts` output
// contains the expected form interfaces, and the IR carries the
// expected $defs entries.
//
// Parity with the Zig goldens (`examples/plugins/*.golden`) is asserted at
// the bottom of this file, on the `kit` / `kit-xor` fixtures: the `.d.ts`
// output is compared byte-for-byte modulo `:description` JSDoc (the one
// construct this port's loader still does not read), and the JSON Schema's
// `allOf` composition + `x-sjon-*` annotations are compared structurally.
// The JSON Schema is not yet byte-comparable end-to-end — key shapes carry
// their own small emission gaps — but the M2 constructs themselves are.

import { test } from 'node:test';
import * as assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { exportSchema } from '../src/Host.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const examples = path.join(root, 'examples/plugins');

function nullHostOptions() {
  return { projectRoot: null, projectFile: null, resolver: null };
}

test('schemaExport: inline plugin emits valid JSON Schema 2020-12', () => {
  const source = `(plugin :name smoke :version "1.0.0"
  (form :name row
    (key :name n :type number)))`;
  const { exportResult } = exportSchema(source, nullHostOptions(), {
    target: { jsonSchema: true, tsTypes: true },
  });
  assert.ok(exportResult.jsonSchemaBytes, 'JSON Schema bytes missing');
  assert.ok(exportResult.tsTypesBytes, 'TS types bytes missing');

  const schema = JSON.parse(exportResult.jsonSchemaBytes);
  assert.equal(
    schema.$schema,
    'https://json-schema.org/draft/2020-12/schema',
    'expected 2020-12 $schema',
  );
  assert.equal(schema['x-sjon-export-version'], 1);
  assert.ok(schema.$defs['form.smoke.row'], 'missing $defs/form.smoke.row');

  // TS surface mentions the form interface.
  assert.match(exportResult.tsTypesBytes, /export interface Smoke_Row\b/);
});

test('schemaExport: :repr emits x-sjon-gpu-repr and a branded TS alias', () => {
  const src = `(plugin :name gpu :version "1.0.0"
  (value-kind :name channel :underlying number :repr (repr-shape :type f32))
  (form :name px
    (key :name r :type channel :optional false)))`;
  const { exportResult } = exportSchema(src, nullHostOptions(), {
    target: { jsonSchema: true, tsTypes: true },
  });
  assert.ok(exportResult.jsonSchemaBytes);
  assert.ok(exportResult.tsTypesBytes);
  // JSON Schema carries the annotation (and, repr-only, no range keywords).
  assert.match(exportResult.jsonSchemaBytes, /"x-sjon-gpu-repr":\s*"f32"/);
  assert.doesNotMatch(exportResult.jsonSchemaBytes, /"minimum"/);
  // The prelude defines the brand and the field renders as it, not `number`.
  assert.match(
    exportResult.tsTypesBytes,
    /export type F32 = number & \{ readonly __sjonRepr\?: "f32" \}/,
  );
  assert.match(exportResult.tsTypesBytes, /r:\s*F32/);
});

test('schemaExport: scalar-or-ref desugars to a resolved anyOf / TS union', () => {
  // `:underlying scalar-or-ref` desugars at load time to
  // `union [count-value symbol]`; the exporter must resolve each
  // alternative (not emit the empty-anyOf stub) — matching the Zig/WASM
  // path that hosts/web and hosts/rust already get through `sjon.wasm`.
  const src = `(plugin :name refs :version "1.0.0"
  (value-kind :name count-value :underlying number)
  (value-kind :name count
    :underlying scalar-or-ref
    :scalar-or-ref (scalar-or-ref-shape :base count-value))
  (form :name use
    (key :name n :type count :optional false)))`;
  const { exportResult } = exportSchema(src, nullHostOptions(), {
    target: { jsonSchema: true, tsTypes: true },
  });
  assert.ok(exportResult.jsonSchemaBytes);
  assert.ok(exportResult.tsTypesBytes);

  const schema = JSON.parse(exportResult.jsonSchemaBytes);
  const n = schema.$defs['form.refs.use'].properties.n; // key shape is inlined
  assert.ok(Array.isArray(n.anyOf));
  assert.equal(n.anyOf.length, 2); // resolved, not the empty stub
  assert.equal(n.anyOf[0].type, 'number'); // count-value → number
  assert.deepEqual(n['x-sjon-union-alternatives'], ['count-value', 'symbol']);
  // The TS surface renders a non-empty union (`number | Symbol_<…>`).
  assert.match(exportResult.tsTypesBytes, /number\s*\|/);
  // Parity warning fires (same `code` string the Zig exporter emits).
  assert.ok(exportResult.warnings.some((w) => w.code === 'union_emitted_via_anyof'));
});

test('schemaExport: unit-shape :reject exports as a plain number (no $num tuple)', () => {
  const rejectSrc = `(plugin :name gfx :version "1.0.0"
  (value-kind :name bare :underlying number :unit (unit-shape :reject true))
  (form :name row
    (key :name x :type bare)))`;
  const reject = exportSchema(rejectSrc, nullHostOptions(), {
    target: { jsonSchema: true, tsTypes: true },
  }).exportResult;
  assert.ok(reject.jsonSchemaBytes);
  assert.ok(reject.tsTypesBytes);
  // A reject kind is unitless — it must not surface as the number_with_unit
  // object (`{$num: [...]}`) or its `[number, unit]` TS tuple.
  assert.doesNotMatch(
    reject.jsonSchemaBytes,
    /\$num/,
    'reject kind emitted a number_with_unit object',
  );
  assert.doesNotMatch(
    reject.tsTypesBytes,
    /\[number,/,
    'reject kind emitted a [number, unit] tuple',
  );

  // Control: a non-reject unit kind DOES emit the unit tuple, proving the
  // `:reject` gate is load-bearing rather than vacuous.
  const unitSrc = `(plugin :name gfx :version "1.0.0"
  (value-kind :name dist :underlying number :unit (unit-shape :allowed [px]))
  (form :name row
    (key :name x :type dist)))`;
  const unit = exportSchema(unitSrc, nullHostOptions(), {
    target: { jsonSchema: true, tsTypes: true },
  }).exportResult;
  assert.ok(unit.jsonSchemaBytes);
  assert.match(
    unit.jsonSchemaBytes,
    /\$num/,
    'non-reject unit kind should emit a number_with_unit object',
  );
});

test('schemaExport: flag-set emits x-sjon-positional-flags annotation', () => {
  const source = `(plugin :name tasks :version "1.0.0"
  (form :name task
    :positional (flag-set
      (flag :name done
        :description "Marks the task as complete."
        :link "https://example.com/docs#done")
      (flag :name archived))))`;
  const { exportResult } = exportSchema(source, nullHostOptions(), {
    target: { jsonSchema: true },
  });
  assert.ok(exportResult.jsonSchemaBytes, 'JSON Schema bytes missing');
  const schema = JSON.parse(exportResult.jsonSchemaBytes);
  const task = schema.$defs['form.tasks.task'];
  assert.ok(task, 'missing $defs/form.tasks.task');
  const flags = task['x-sjon-positional-flags'];
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

test('schemaExport: bounded head-set emits contains/minContains/maxContains', () => {
  // The `$children` array keeps the whole-set `items` union; the per-head
  // counts ride in `allOf` beside it. NOT minItems/maxItems, which bound
  // the array's total length — a different claim.
  const source = `(plugin :name gfx :version "1.0.0"
  (form :name vertex)
  (form :name fragment)
  (form :name constant)
  (value-kind :name pipeline-section :underlying form
    :heads (head-set
      (head :name vertex   :min 1 :max 1)
      (head :name fragment :max 1)
      (head :name constant)))
  (form :name render-pipeline :positional pipeline-section))`;
  const { exportResult } = exportSchema(source, nullHostOptions(), {
    target: { jsonSchema: true, tsTypes: true },
  });
  assert.ok(exportResult.jsonSchemaBytes, 'JSON Schema bytes missing');
  const schema = JSON.parse(exportResult.jsonSchemaBytes);
  const children = schema.$defs['form.gfx.render-pipeline'].properties.$children;
  assert.ok(children.items, '$children.items missing — the whole-set union must survive');
  assert.equal(children.minItems, undefined);
  assert.equal(children.maxItems, undefined);
  assert.deepEqual(children.allOf, [
    { contains: { $ref: '#/$defs/form.gfx.vertex' }, minContains: 1, maxContains: 1 },
    // `minContains: 0` is explicit: without it `contains` would also
    // demand at least one match, making "at most one" mean "exactly one".
    { contains: { $ref: '#/$defs/form.gfx.fragment' }, minContains: 0, maxContains: 1 },
  ]);

  // TS cannot express a per-member array count, so the bounds are prose.
  assert.ok(exportResult.tsTypesBytes, 'TS bytes missing');
  assert.ok(
    exportResult.tsTypesBytes.includes(
      'Positional counts (not expressible in TS): vertex: 1; fragment: 0..1 */',
    ),
    'the $children doc comment must match the Zig emitter byte for byte',
  );
});

test('schemaExport: an unbounded head-set adds no allOf and no doc comment', () => {
  // The drift gate for every golden written before bounds existed.
  const source = `(plugin :name gfx :version "1.0.0"
  (form :name vertex)
  (form :name fragment)
  (value-kind :name loose-section :underlying form
    :heads (head-set :names [vertex fragment]))
  (form :name loose :positional loose-section))`;
  const { exportResult } = exportSchema(source, nullHostOptions(), {
    target: { jsonSchema: true, tsTypes: true },
  });
  assert.ok(exportResult.jsonSchemaBytes, 'JSON Schema bytes missing');
  const schema = JSON.parse(exportResult.jsonSchemaBytes);
  const children = schema.$defs['form.gfx.loose'].properties.$children;
  assert.ok(children.items, '$children.items missing');
  assert.equal(children.allOf, undefined);
  assert.ok(exportResult.tsTypesBytes, 'TS bytes missing');
  assert.ok(!exportResult.tsTypesBytes.includes('Positional counts'));
});

test('schemaExport: empty-string flag metadata matches Zig (desc omitted, link kept)', () => {
  // Long-tail parity: the Zig emitter gates `description` on `len > 0`
  // (so `:description ""` is dropped) but emits `link` on presence alone
  // (so `:link ""` survives as `""`). The TS exporter must reproduce that
  // exact asymmetry, or the `x-sjon-positional-flags` annotation diverges
  // from the reference host.
  const source = `(plugin :name tasks :version "1.0.0"
  (form :name task
    :positional (flag-set
      (flag :name done :description "")
      (flag :name archived :link ""))))`;
  const { exportResult } = exportSchema(source, nullHostOptions(), {
    target: { jsonSchema: true },
  });
  assert.ok(exportResult.jsonSchemaBytes, 'JSON Schema bytes missing');
  const schema = JSON.parse(exportResult.jsonSchemaBytes);
  const flags = schema.$defs['form.tasks.task']['x-sjon-positional-flags'];
  // Empty description is dropped → name-only, exactly like Zig.
  assert.deepEqual(flags[0], { name: 'done' });
  // Empty link is preserved as "" → present-but-empty, exactly like Zig.
  assert.deepEqual(flags[1], { name: 'archived', link: '' });
});

test('schemaExport: aggregated layout has no perPlugin block', () => {
  const source = `(plugin :name smoke :version "1.0.0"
  (form :name row (key :name n :type number)))`;
  const { exportResult } = exportSchema(source, nullHostOptions(), {});
  assert.equal(exportResult.perPlugin, null);
});

test('schemaExport: per-plugin layout returns one artifact per plugin', () => {
  const source = `(plugin :name a :version "1.0.0"
  (form :name r (key :name n :type number)))
(plugin :name b :version "1.0.0"
  (form :name s (key :name m :type number)))`;
  const { exportResult } = exportSchema(source, nullHostOptions(), {
    layout: 'per-plugin',
    target: { jsonSchema: true },
  });
  assert.ok(exportResult.perPlugin, 'perPlugin must be populated');
  assert.equal(exportResult.perPlugin.length, 2);
  const names = exportResult.perPlugin.map((a) => a.plugin);
  assert.ok(names.includes('a'));
  assert.ok(names.includes('b'));
  for (const art of exportResult.perPlugin) {
    assert.ok(art.jsonSchema, `plugin ${art.plugin} missing JSON Schema`);
    const parsed = JSON.parse(art.jsonSchema);
    assert.ok(parsed.$defs, `plugin ${art.plugin} missing $defs`);
  }
});

test('schemaExport: bounds manifest emits numeric + string keywords', () => {
  const manifestPath = path.join(examples, 'bounds/plugin.sjon');
  if (!existsSync(manifestPath)) return;
  const src = readFileSync(manifestPath, 'utf8');
  const { exportResult } = exportSchema(src, nullHostOptions(), {
    target: { jsonSchema: true, tsTypes: true },
  });
  assert.ok(exportResult.jsonSchemaBytes);
  const schema = JSON.parse(exportResult.jsonSchemaBytes);
  const profile = schema.$defs['form.bounds.profile'];
  assert.ok(profile, 'missing $defs/form.bounds.profile');

  // Spot-check: the `score` key threads its numeric bounds (0..100).
  const scoreSchema = profile.properties.score;
  assert.ok(scoreSchema, 'score key missing from profile.properties');
  // `score` is optional; the value-kind `score` carries the bounds.
  // Look it up via the resolved shape, not through a direct property
  // because lowering inlines the bound on the key shape.
  // (The exact key here is `score` because the manifest uses that name.)
  const sb = scoreSchema as Record<string, unknown>;
  assert.equal(sb['type'], 'number');
  assert.equal(sb['minimum'], 0);
  assert.equal(sb['maximum'], 100);
});

test('schemaExport: warnings include lossiness annotations', () => {
  const manifestPath = path.join(examples, 'bounds/plugin.sjon');
  if (!existsSync(manifestPath)) return;
  const src = readFileSync(manifestPath, 'utf8');
  const { exportResult } = exportSchema(src, nullHostOptions(), {});
  const codes = new Set(exportResult.warnings.map((w) => w.code));
  // The bounds plugin uses numeric bounds, string bounds, and a > 2^53
  // exact-int bound; each should surface as a warning.
  assert.ok(
    codes.has('numeric_bounds_emitted_via_min_max') ||
      codes.has('string_bounds_emitted_via_keywords'),
    `expected bounds-related warnings; got ${[...codes].join(', ')}`,
  );
});

test('schemaExport: slot-local forms emit an inline anyOf + open branch and a TS union', () => {
  const src = `(plugin :name lf :version "1.0.0"
  (form :name canvas
    (key :name shape :type form :optional false
      (form :name circle (key :name r :type number :optional false))
      (form :name rect (key :name w :type number :optional false)))))`;
  const { exportResult } = exportSchema(src, nullHostOptions(), {
    target: { jsonSchema: true, tsTypes: true },
  });
  assert.ok(exportResult.jsonSchemaBytes, 'JSON Schema bytes missing');
  assert.ok(exportResult.tsTypesBytes, 'TS types bytes missing');

  // JSON: the :shape slot is an inline anyOf of the two local form bodies
  // plus a trailing open generic branch for the additive global fallback.
  // anyOf (not oneOf) so the open branch may overlap the specific ones.
  const schema = JSON.parse(exportResult.jsonSchemaBytes);
  const shape = schema.$defs['form.lf.canvas'].properties.shape;
  assert.ok(Array.isArray(shape.anyOf), 'shape should be an inline anyOf');
  assert.equal(shape.anyOf.length, 3, 'circle + rect + open branch');
  assert.deepEqual(shape['x-sjon-local-forms'], ['circle', 'rect']);
  assert.deepEqual(shape.anyOf[2], { type: 'object', required: ['$form'] });

  // TS: the slot is an inline union — the circle branch plus the open arm.
  assert.match(
    exportResult.tsTypesBytes,
    /shape: \{ \$form: "circle"; \$ns\?: string; r: number; \}/,
  );
  assert.match(
    exportResult.tsTypesBytes,
    /\| \{ readonly \$form: string; readonly \$ns\?: string \}/,
  );

  // The inline emission is recorded as an info warning.
  const codes = new Set(exportResult.warnings.map((w) => w.code));
  assert.ok(codes.has('local_forms_emitted_inline'), `got ${[...codes].join(', ')}`);
});

test('schemaExport: the two cross-ref routes render differently in every target', () => {
  const src = `(plugin :name gfx :version "1.0.0" :sjon "1.2"
  (cross-ref-provider :name uniforms)
  (form :name shader
    (key :name name :type symbol :optional false)
    (key :name code :type string :optional false))
  (form :name layer
    (key :name name :type symbol :optional false))
  (value-kind :name uniform-ref
    :underlying symbol
    :cross-ref (cross-ref :target shader :provider uniforms :source-key code))
  (value-kind :name layer-ref
    :underlying symbol
    :cross-ref (cross-ref :target layer))
  (form :name bind
    (key :name uniform :type uniform-ref :optional false)
    (key :name layer :type layer-ref :optional false)))`;
  const { exportResult } = exportSchema(src, nullHostOptions(), {
    target: { jsonSchema: true, tsTypes: true },
  });
  assert.ok(exportResult.jsonSchemaBytes, 'JSON Schema bytes missing');
  assert.ok(exportResult.tsTypesBytes, 'TS types bytes missing');

  const schema = JSON.parse(exportResult.jsonSchemaBytes);
  const props = schema.$defs['form.gfx.bind'].properties;
  // Provider route: the two members are present, and `name-key` / `acyclic`
  // stay unconditional so the annotation keeps one field set on both routes.
  assert.deepEqual(props.uniform['x-sjon-cross-ref'], {
    'target-form': 'shader',
    'name-key': 'name',
    acyclic: false,
    provider: 'uniforms',
    'source-key': 'code',
  });
  // Identity route: omitted, not spelled `null` — same rule as `scope-form`.
  assert.deepEqual(props.layer['x-sjon-cross-ref'], {
    'target-form': 'layer',
    'name-key': 'name',
    acyclic: false,
  });

  // TS JSDoc names only what each route carries. An annotation always
  // renders in block form (matching `TsTypes.zig`'s `use_block`), so the
  // line ends at the newline, not at a `*/`.
  assert.match(
    exportResult.tsTypesBytes,
    /@sjon-cross-ref target=shader provider=uniforms source-key=code\n/,
  );
  assert.match(
    exportResult.tsTypesBytes,
    /@sjon-cross-ref target=layer name-key=name acyclic=false\n/,
  );

  // Both routes warn, and the provider route's message says why it is
  // unenforceable for a second reason: there is no document at export time.
  const messages = exportResult.warnings
    .filter((w) => w.code === 'cross_ref_unenforceable')
    .map((w) => w.message);
  assert.equal(messages.length, 2);
  assert.ok(
    messages.some(
      (m) => m.includes('provider `uniforms`') && m.includes('not knowable at export time'),
    ),
    `got ${messages.join(' | ')}`,
  );
});

// ── Cross-exporter comparison: the M2 constructs ────────────────────────
//
// The file header used to call byte-parity with the Zig goldens a stretch
// goal blocked on the loader. The loader now parses discriminators and
// exclusive groups, so the two exporters can finally be compared on them —
// against `examples/plugins/{kit,kit-xor}`, the fixtures that exist for
// exactly these constructs.
//
// One gap remains and is named rather than normalised away: this port's
// loader does not read `:description`, so every golden line that carries
// author prose is dropped before comparing. Nothing else is.

function goldenOrSkip(rel: string): string | null {
  const p = path.join(examples, rel);
  return existsSync(p) ? readFileSync(p, 'utf8') : null;
}

function exportOf(fixture: string) {
  const manifestPath = path.join(examples, fixture, 'plugin.sjon');
  if (!existsSync(manifestPath)) return null;
  const { exportResult } = exportSchema(readFileSync(manifestPath, 'utf8'), nullHostOptions(), {
    target: { jsonSchema: true, tsTypes: true },
  });
  return exportResult;
}

/** Drop the JSDoc a `:description` produces: a whole single-line `/** … *​/`,
 *  a prose line inside a multi-line block, and the `*` separator that only
 *  existed to space prose from the `@sjon-…` annotations below it. The
 *  annotation lines themselves are kept — they are what this compares.
 *
 *  Continuation lines carry the member's indentation on both emitters, so
 *  the prose and separator patterns allow leading whitespace. A single-line
 *  block containing an `@`-annotation is NOT a description and is kept —
 *  both emitters reserve the single-line shape for lone prose. */
function withoutDescriptionDoc(src: string): string {
  return src
    .split('\n')
    .filter(
      (l) => !/^\s*\/\*\*(?!.*@).*\*\/$/.test(l) && !/^\s*\* [^@]/.test(l) && l.trim() !== '*',
    )
    .join('\n');
}

test('schemaExport: kit-xor exclusive groups match the Zig golden exactly', () => {
  const result = exportOf('kit-xor');
  const golden = goldenOrSkip('kit-xor/kit-xor.schema.json.golden');
  if (!result || !golden) return;
  const ours = JSON.parse(result.jsonSchemaBytes!)['$defs'];
  const theirs = JSON.parse(golden)['$defs'];
  for (const def of ['form.kit-xor.phrase', 'form.kit-xor.tag']) {
    // `phrase` is exactly-one → `oneOf`; `tag` is at-most-one → `not:{allOf}`.
    assert.deepEqual(ours[def].allOf, theirs[def].allOf, `${def} allOf`);
    assert.deepEqual(
      ours[def]['x-sjon-exclusive-groups'],
      theirs[def]['x-sjon-exclusive-groups'],
      `${def} annotation`,
    );
    // A group composes via allOf, so the schema must close with
    // `unevaluatedProperties` — `additionalProperties` cannot see what a
    // sibling sub-schema evaluated.
    assert.equal(ours[def].unevaluatedProperties, theirs[def].unevaluatedProperties);
    assert.equal(ours[def].additionalProperties, undefined);
  }
});

test('schemaExport: kit variant overlays match the Zig golden', () => {
  const result = exportOf('kit');
  const golden = goldenOrSkip('kit/kit.schema.json.golden');
  if (!result || !golden) return;
  const ours = JSON.parse(result.jsonSchemaBytes!)['$defs']['form.kit.track'];
  const theirs = JSON.parse(golden)['$defs']['form.kit.track'];
  assert.deepEqual(ours['x-sjon-discriminant'], theirs['x-sjon-discriminant']);
  assert.equal(ours.allOf.length, theirs.allOf.length);
  for (let i = 0; i < theirs.allOf.length; i++) {
    // The `if` gate is fully comparable; the `then` body carries key shapes
    // whose emission has pre-existing gaps of its own (`:description`,
    // `items: {}` on an untyped vector), so only its `required` is compared.
    assert.deepEqual(ours.allOf[i].if, theirs.allOf[i].if, `variant ${i} if`);
    assert.deepEqual(
      ours.allOf[i].then.required,
      theirs.allOf[i].then.required,
      `variant ${i} then.required`,
    );
  }
  assert.equal(ours.unevaluatedProperties, theirs.unevaluatedProperties);
});

for (const fixture of ['kit', 'kit-xor']) {
  test(`schemaExport: ${fixture} .d.ts matches the Zig golden (minus :description)`, () => {
    const result = exportOf(fixture);
    const golden = goldenOrSkip(`${fixture}/${fixture}.d.ts.golden`);
    if (!result || !golden) return;
    assert.equal(
      withoutDescriptionDoc(result.tsTypesBytes!),
      withoutDescriptionDoc(golden),
      `${fixture} .d.ts drifted from the Zig exporter`,
    );
  });
}
