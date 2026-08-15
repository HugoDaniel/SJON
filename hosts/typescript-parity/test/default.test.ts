// Cross-host defaults parity (TS-parity side). Covers the in-scope surface:
// the loader parses `:default`, `effectiveOptional` honours it, the validator
// does not flag an omitted defaulted key, and the exporter emits it as an
// optional (authoring-shape) field matching the Zig reference.
//
// Explicitly NOT covered (mirrors test/conformance.test.ts skip notes): the
// `default-*` / `effective-axis-*` corpus cases, which need an Expr evaluator,
// the materialization overlay, and a `validateDefaults` pass this host does
// not implement. Default *value* type-checking (`wrong_underlying`) is part of
// that out-of-scope machinery.

import test from 'node:test';
import assert from 'node:assert';

import { type HostDiagnostic, exportSchema, validateDocument } from '../src/Host.ts';
import { loadManifest } from '../src/loader.ts';
import { parse } from '../src/parser.ts';
import { effectiveOptional } from '../src/plugin.ts';
import type { Diagnostic } from '../src/diagnostics.ts';

function codes(diags: readonly HostDiagnostic[]): readonly string[] {
  return diags.map((d) => d.code);
}

function nullHostOptions() {
  return { projectRoot: null, projectFile: null, resolver: null };
}

function validate(src: string): readonly HostDiagnostic[] {
  return validateDocument(src, { projectRoot: null, resolver: null, projectFile: null })
    .diagnostics;
}

function load(src: string) {
  const diags: Diagnostic[] = [];
  const roots = parse(src, diags);
  assert.strictEqual(
    diags.filter((d) => d.severity === 'err').length,
    0,
    `parse errors: ${JSON.stringify(diags)}`,
  );
  return loadManifest(roots);
}

// --- Loader: :default parsing ----------------------------------------------

test('loader parses :default literals into KeySpec.default', () => {
  const r = load(`(plugin :name p :version "1.0.0"
    (form :name doc
      (key :name title :type string :optional false :default "Untitled")
      (key :name count :type number :optional false :default 0)
      (key :name mode :type symbol :optional false :default fast)
      (key :name origin :type vector :optional false :default [0 0])
      (key :name plain :type string :optional false)))`);
  assert.strictEqual(r.errors.length, 0);
  const form = r.plugin.forms.find((f) => f.name === 'doc')!;
  const byName = (n: string) => form.keys.find((k) => k.name === n)!;
  assert.deepEqual(byName('title').default, { kind: 'string', value: 'Untitled' });
  assert.deepEqual(byName('count').default, { kind: 'number', value: 0 });
  assert.deepEqual(byName('mode').default, { kind: 'symbol', value: 'fast' });
  assert.deepEqual(byName('origin').default, {
    kind: 'vector',
    elements: [
      { kind: 'number', value: 0 },
      { kind: 'number', value: 0 },
    ],
  });
  assert.equal(byName('plain').default ?? null, null);
});

test('loader parses an expression :default into a head/argCount snapshot', () => {
  const r = load(`(plugin :name p :version "1.0.0"
    (form :name scene
      (key :name fps :type number :optional false :default (pi))))`);
  const k = r.plugin.forms[0]!.keys[0]!;
  assert.deepEqual(k.default, { kind: 'expression', head: 'pi', namespace: null, argCount: 0 });
});

test('effectiveOptional: a defaulted key is effectively optional', () => {
  const r = load(`(plugin :name p :version "1.0.0"
    (form :name doc
      (key :name req :type string :optional false)
      (key :name def :type string :optional false :default "x")
      (key :name opt :type string :optional true)))`);
  const form = r.plugin.forms[0]!;
  const byName = (n: string) => form.keys.find((k) => k.name === n)!;
  assert.equal(effectiveOptional(byName('req')), false);
  assert.equal(effectiveOptional(byName('def')), true); // default ⇒ effectively optional
  assert.equal(effectiveOptional(byName('opt')), true);
});

// --- Validator: defaulted key is not missing_required_key ------------------

const DOC = `(plugin :name p :version "1.0.0"
  (form :name doc
    (key :name id :type string :optional false)
    (key :name radius :type number :optional false :default 32)))`;

test('an omitted :optional false :default key does NOT emit missing_required_key', () => {
  // `radius` is required-but-defaulted; only the truly-required `id` is given.
  const c = codes(validate(`${DOC}\n\n(doc :id "a")`));
  assert.ok(
    !c.includes('missing_required_key'),
    `unexpected missing_required_key in ${JSON.stringify(c)}`,
  );
});

test('an omitted required-no-default key still emits missing_required_key (control)', () => {
  const c = codes(validate(`${DOC}\n\n(doc :radius 5)`));
  assert.ok(
    c.includes('missing_required_key'),
    `expected missing_required_key in ${JSON.stringify(c)}`,
  );
});

test('providing both keys validates cleanly', () => {
  const errs = validate(`${DOC}\n\n(doc :id "a" :radius 5)`).filter((d) => d.severity === 'err');
  assert.deepEqual(errs, []);
});

// --- Exporter: defaulted keys are optional (authoring shape), matching Zig --

const EXPORT_DOC = `(plugin :name p :version "1.0.0"
  (form :name doc
    (key :name id :type string :optional false)
    (key :name title :type string :optional false :default "Untitled")
    (key :name count :type number :optional false :default 0)))`;

test('exporter emits a defaulted key as OPTIONAL in the .d.ts (authoring shape)', () => {
  const { exportResult } = exportSchema(EXPORT_DOC, nullHostOptions(), {
    target: { tsTypes: true },
  });
  const dts = exportResult.tsTypesBytes ?? '';
  assert.match(dts, /\bid: string/); // truly required → no `?`
  assert.match(dts, /\btitle\?: string/); // defaulted ⇒ optional
  assert.match(dts, /\bcount\?: number/);
  // Scalar defaults carry no @default JSDoc (matches the Zig exporter, which
  // annotates expression defaults only).
  assert.doesNotMatch(dts, /@default/);
});

test('exporter surfaces a literal default in the JSON Schema', () => {
  const { exportResult } = exportSchema(EXPORT_DOC, nullHostOptions(), {
    target: { jsonSchema: true },
  });
  const json = exportResult.jsonSchemaBytes ?? '';
  assert.match(json, /"default":\s*"Untitled"/);
  assert.match(json, /"default":\s*0/);
});
