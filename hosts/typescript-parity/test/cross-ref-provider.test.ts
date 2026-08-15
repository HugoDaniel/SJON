// Provider-route cross-refs (manifest format 1.2) — the declarative half.
//
// This host implements the declaration surface in full: the fourth catalog,
// the two new `(cross-ref …)` keys, the three route exclusions, and the
// three schema-aggregate codes. It implements none of the *executable*
// half — extraction is a host pre-pass over a WASM ABI, outside this port's
// declarative-only scope — so nothing here runs a provider.
//
// Mirrors `src/ManifestLoader_tests.zig` and the `validateCrossRefs`
// provider tests in `src/Schema.zig`; messages are byte-identical to Zig's
// by the standing parity rule.

import test from 'node:test';
import assert from 'node:assert';

import { parse } from '../src/parser.ts';
import { loadManifest } from '../src/loader.ts';
import { validateCrossRefs } from '../src/plugin.ts';
import type { Schema } from '../src/plugin.ts';
import type { Diagnostic } from '../src/diagnostics.ts';

function manifestRootsOrThrow(src: string) {
  const diags: Diagnostic[] = [];
  const roots = parse(src, diags);
  const parseErrs = diags.filter((d) => d.severity === 'err');
  assert.strictEqual(parseErrs.length, 0, `parse errors: ${JSON.stringify(parseErrs)}`);
  return roots;
}

function schemaOf(src: string): { schema: Schema; loadDiags: readonly Diagnostic[] } {
  const r = loadManifest(manifestRootsOrThrow(src));
  return { schema: { plugins: [r.plugin] }, loadDiags: r.diagnostics };
}

// ── the fourth catalog ───────────────────────────────────────────────────

test('provider: (cross-ref-provider …) lands in the fourth catalog', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (cross-ref-provider :name uniforms :description "GLSL uniforms." :impl "wasm:extract_uniforms"))',
    ),
  );
  assert.strictEqual(r.errors.length, 0);
  assert.strictEqual(r.plugin.crossRefProviders.length, 1);
  assert.strictEqual(r.plugin.crossRefProviders[0]?.name, 'uniforms');
  assert.strictEqual(r.plugin.crossRefProviders[0]?.description, 'GLSL uniforms.');
  // `:impl` is dropped on the floor, as it is for expr-funcs on this host.
  assert.ok(!('impl' in (r.plugin.crossRefProviders[0] as object)));
});

test('provider: a manifest with no providers still carries an empty catalog', () => {
  const r = loadManifest(manifestRootsOrThrow('(plugin :name p :version "1.0.0")'));
  assert.deepStrictEqual(r.plugin.crossRefProviders, []);
});

// ── the two route keys ───────────────────────────────────────────────────

test('provider: :provider and :source-key land on the cross-ref spec', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (cross-ref-provider :name uniforms) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider uniforms :target shader :source-key body)))',
    ),
  );
  assert.strictEqual(r.diagnostics.length, 0);
  const cr = r.plugin.valueKinds[0]?.crossRef;
  assert.strictEqual(cr?.provider, 'uniforms');
  assert.strictEqual(cr?.sourceKey, 'body');
  // The identity field stays unwritten; nothing consults it on this route.
  assert.strictEqual(cr?.nameKey, undefined);
});

test('provider: identity-route cross-refs are untouched by the new keys', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (value-kind :name phrase-name :underlying symbol :cross-ref (cross-ref :target phrase :name-key id :scope piece)))',
    ),
  );
  const cr = r.plugin.valueKinds[0]?.crossRef;
  assert.strictEqual(cr?.provider, undefined);
  assert.strictEqual(cr?.sourceKey, undefined);
  assert.strictEqual(cr?.nameKey, 'id');
  assert.strictEqual(cr?.scopeForm, 'piece');
});

// ── the three exclusions ─────────────────────────────────────────────────

test('provider: :provider with :name-key is invalid_manifest and drops :name-key', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (cross-ref-provider :name uniforms) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider uniforms :target shader :name-key id)))',
    ),
  );
  const d = r.diagnostics.find((x) => x.code === 'invalid_manifest');
  assert.ok(d, 'expected invalid_manifest');
  assert.ok(d!.message.includes('extraction routes are exclusive'));
  assert.deepStrictEqual(d!.path, ['uniform-name', 'cross-ref', 'name-key']);
  // Dropped, not half-honoured.
  assert.strictEqual(r.plugin.valueKinds[0]?.crossRef?.nameKey, undefined);
});

test('provider: :provider with :acyclic true is invalid_manifest and drops :acyclic', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (cross-ref-provider :name uniforms) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider uniforms :target shader :acyclic true)))',
    ),
  );
  const d = r.diagnostics.find((x) => x.code === 'invalid_manifest');
  assert.ok(d, 'expected invalid_manifest');
  assert.ok(d!.message.includes(':acyclic true'));
  assert.strictEqual(r.plugin.valueKinds[0]?.crossRef?.acyclic, false);
});

test('provider: :acyclic false alongside :provider is not an error', () => {
  // The exclusion is about an *active* cycle check, not the key's presence.
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (cross-ref-provider :name uniforms) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider uniforms :target shader :acyclic false)))',
    ),
  );
  assert.strictEqual(r.diagnostics.filter((d) => d.code === 'invalid_manifest').length, 0);
});

test('provider: :source-key without :provider is invalid_manifest and drops it', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (value-kind :name phrase-name :underlying symbol :cross-ref (cross-ref :target phrase :source-key body)))',
    ),
  );
  const d = r.diagnostics.find((x) => x.code === 'invalid_manifest');
  assert.ok(d, 'expected invalid_manifest');
  assert.ok(d!.message.includes('without `:provider`'));
  assert.strictEqual(r.plugin.valueKinds[0]?.crossRef?.sourceKey, undefined);
});

// ── the three aggregate codes ────────────────────────────────────────────

const SHADER_FORM = '(form :name shader (key :name src :type string :optional false))';

test('aggregate: provider route with a string source-key resolves cleanly', () => {
  const { schema } = schemaOf(
    `(plugin :name p :version "1.0.0" ${SHADER_FORM} (cross-ref-provider :name uniforms) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider uniforms :target shader)))`,
  );
  assert.deepStrictEqual(validateCrossRefs(schema), []);
});

test('aggregate: unknown provider emits unknown_cross_ref_provider', () => {
  const { schema } = schemaOf(
    `(plugin :name p :version "1.0.0" ${SHADER_FORM} (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider nope :target shader)))`,
  );
  const diags = validateCrossRefs(schema);
  assert.strictEqual(diags.length, 1);
  assert.strictEqual(diags[0]?.code, 'unknown_cross_ref_provider');
  assert.strictEqual(
    diags[0]?.message,
    'value-kind `uniform-name` cross-ref `:provider nope` does not resolve to any declared provider',
  );
  assert.deepStrictEqual(diags[0]?.path, ['p', 'uniform-name', 'cross-ref']);
});

test('aggregate: a bare provider claimed by two plugins is ambiguous', () => {
  const a = loadManifest(
    manifestRootsOrThrow('(plugin :name a :version "1.0.0" (cross-ref-provider :name uniforms))'),
  );
  const b = loadManifest(
    manifestRootsOrThrow(
      `(plugin :name b :version "1.0.0" ${SHADER_FORM} (cross-ref-provider :name uniforms) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider uniforms :target shader)))`,
    ),
  );
  const diags = validateCrossRefs({ plugins: [a.plugin, b.plugin] });
  assert.strictEqual(diags.length, 1);
  assert.strictEqual(diags[0]?.code, 'ambiguous_cross_ref_provider');
  assert.strictEqual(
    diags[0]?.message,
    'value-kind `uniform-name` cross-ref `:provider uniforms` is ambiguous — defined by [a, b]; qualify with `<ns>/uniforms`',
  );
});

test('aggregate: a qualified provider picks one plugin out of a collision', () => {
  const a = loadManifest(
    manifestRootsOrThrow('(plugin :name a :version "1.0.0" (cross-ref-provider :name uniforms))'),
  );
  const b = loadManifest(
    manifestRootsOrThrow(
      `(plugin :name b :version "1.0.0" ${SHADER_FORM} (cross-ref-provider :name uniforms) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider a/uniforms :target shader)))`,
    ),
  );
  assert.deepStrictEqual(validateCrossRefs({ plugins: [a.plugin, b.plugin] }), []);
});

test('aggregate: an absent source-key emits cross_ref_source_key_unknown', () => {
  const { schema } = schemaOf(
    `(plugin :name p :version "1.0.0" ${SHADER_FORM} (cross-ref-provider :name uniforms) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider uniforms :target shader :source-key body)))`,
  );
  const diags = validateCrossRefs(schema);
  assert.strictEqual(diags.length, 1);
  assert.strictEqual(diags[0]?.code, 'cross_ref_source_key_unknown');
  assert.strictEqual(
    diags[0]?.message,
    'value-kind `uniform-name` cross-ref `:source-key body` is not a string-typed key on form `shader`',
  );
});

test('aggregate: a non-string source-key emits cross_ref_source_key_unknown', () => {
  const { schema } = schemaOf(
    '(plugin :name p :version "1.0.0" (form :name shader (key :name src :type number :optional false)) (cross-ref-provider :name uniforms) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider uniforms :target shader)))',
  );
  const diags = validateCrossRefs(schema);
  assert.strictEqual(diags.length, 1);
  assert.strictEqual(diags[0]?.code, 'cross_ref_source_key_unknown');
});

test('aggregate: a string-underlying named kind satisfies :source-key', () => {
  const { schema } = schemaOf(
    '(plugin :name p :version "1.0.0" (form :name shader (key :name src :type glsl-source :optional false)) (cross-ref-provider :name uniforms) (value-kind :name glsl-source :underlying string) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider uniforms :target shader)))',
  );
  assert.deepStrictEqual(validateCrossRefs(schema), []);
});

test('aggregate: the provider route never checks :name-key', () => {
  // The routes dispatch, they do not stack: a provider-backed spec whose
  // target has no `:name` key must stay quiet.
  const { schema } = schemaOf(
    `(plugin :name p :version "1.0.0" ${SHADER_FORM} (cross-ref-provider :name uniforms) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider uniforms :target shader)))`,
  );
  assert.strictEqual(
    validateCrossRefs(schema).filter((d) => d.code === 'cross_ref_name_key_unknown').length,
    0,
  );
});

test('aggregate: an unresolved target and an unresolved provider both diagnose', () => {
  const { schema } = schemaOf(
    '(plugin :name p :version "1.0.0" (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider also-nope :target nope)))',
  );
  assert.deepStrictEqual(
    validateCrossRefs(schema).map((d) => d.code),
    ['unknown_cross_ref_target', 'unknown_cross_ref_provider'],
  );
});

// ── target collapse ──────────────────────────────────────────────────────
//
// One target form, one member set, built first-wins. Detecting a collapse
// needs only the declarations, so this host emits the warning in full —
// unlike the two extraction codes, which need a running provider.

const COLLAPSE_SHADER_FORM =
  '(form :name shader (key :name name :type symbol :optional false) (key :name src :type string :optional false))';

test('collapse: identity and provider routes on one target warn', () => {
  const { schema } = schemaOf(
    `(plugin :name gl :version "1.0.0" ${COLLAPSE_SHADER_FORM} (cross-ref-provider :name uniforms) (value-kind :name shader-name :underlying symbol :cross-ref (cross-ref :target shader)) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider uniforms :target shader)))`,
  );
  const diags = validateCrossRefs(schema);
  assert.strictEqual(diags.length, 1);
  assert.strictEqual(diags[0]?.code, 'cross_ref_target_collapse');
  assert.strictEqual(diags[0]?.severity, 'warning');
  // Byte-identical to `src/Schema.zig`'s, per the standing parity rule.
  assert.strictEqual(
    diags[0]?.message,
    'value-kind `uniform-name` cross-references form `gl/shader`, whose members are already ' +
      "collected by value-kind `shader-name` in plugin `gl` using `:name-key name`; this kind's " +
      '`:provider gl/uniforms` over `:source-key src` is ignored, and its references are checked ' +
      "against the other kind's names",
  );
  // Pathed at the loser — the kind whose declaration is inert.
  assert.deepStrictEqual(diags[0]?.path, ['gl', 'uniform-name', 'cross-ref']);
});

test('collapse: declaration order decides which route wins', () => {
  const { schema } = schemaOf(
    `(plugin :name gl :version "1.0.0" ${COLLAPSE_SHADER_FORM} (cross-ref-provider :name uniforms) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider uniforms :target shader)) (value-kind :name shader-name :underlying symbol :cross-ref (cross-ref :target shader)))`,
  );
  const diags = validateCrossRefs(schema);
  assert.strictEqual(diags.length, 1);
  assert.deepStrictEqual(diags[0]?.path, ['gl', 'shader-name', 'cross-ref']);
});

test('collapse: two kinds aliasing one target identically stay silent', () => {
  const { schema } = schemaOf(
    `(plugin :name gl :version "1.0.0" ${COLLAPSE_SHADER_FORM} (value-kind :name vertex-ref :underlying symbol :cross-ref (cross-ref :target shader)) (value-kind :name fragment-ref :underlying symbol :cross-ref (cross-ref :target shader)))`,
  );
  assert.deepStrictEqual(validateCrossRefs(schema), []);
});

test('collapse: a bare and a qualified :provider spelling agree', () => {
  // The comparison is canonical, so the two spellings of one provider are
  // the same registry and there is nothing to warn about.
  const { schema } = schemaOf(
    `(plugin :name gl :version "1.0.0" ${COLLAPSE_SHADER_FORM} (cross-ref-provider :name uniforms) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider uniforms :target shader)) (value-kind :name uniform-ref :underlying symbol :cross-ref (cross-ref :provider gl/uniforms :target shader)))`,
  );
  assert.deepStrictEqual(validateCrossRefs(schema), []);
});

test('collapse: same route, different :name-key warns', () => {
  const { schema } = schemaOf(
    '(plugin :name gl :version "1.0.0" (form :name shader (key :name name :type symbol :optional false) (key :name alias :type symbol :optional false)) (value-kind :name by-name :underlying symbol :cross-ref (cross-ref :target shader)) (value-kind :name by-alias :underlying symbol :cross-ref (cross-ref :target shader :name-key alias)))',
  );
  const diags = validateCrossRefs(schema);
  assert.strictEqual(diags.length, 1);
  assert.strictEqual(diags[0]?.code, 'cross_ref_target_collapse');
  assert.deepStrictEqual(diags[0]?.path, ['gl', 'by-alias', 'cross-ref']);
});

test('collapse: a differing :scope warns and is named canonically', () => {
  const { schema } = schemaOf(
    `(plugin :name gl :version "1.0.0" ${COLLAPSE_SHADER_FORM} (form :name pass) (value-kind :name global-ref :underlying symbol :cross-ref (cross-ref :target shader)) (value-kind :name scoped-ref :underlying symbol :cross-ref (cross-ref :target shader :scope pass)))`,
  );
  const diags = validateCrossRefs(schema);
  assert.strictEqual(diags.length, 1);
  assert.strictEqual(diags[0]?.code, 'cross_ref_target_collapse');
  assert.ok(diags[0]?.message.includes('scoped to `gl/pass`'));
});

test('collapse: every loser is compared against the first winner', () => {
  // Not a chain: `third` disagrees with `second` but agrees with `first`,
  // so only `second` warns.
  const { schema } = schemaOf(
    `(plugin :name gl :version "1.0.0" ${COLLAPSE_SHADER_FORM} (cross-ref-provider :name uniforms) (value-kind :name first :underlying symbol :cross-ref (cross-ref :target shader)) (value-kind :name second :underlying symbol :cross-ref (cross-ref :provider uniforms :target shader)) (value-kind :name third :underlying symbol :cross-ref (cross-ref :target shader)))`,
  );
  const diags = validateCrossRefs(schema);
  assert.strictEqual(diags.length, 1);
  assert.deepStrictEqual(diags[0]?.path, ['gl', 'second', 'cross-ref']);
});

test('collapse: spans plugins, in load order', () => {
  const gl = loadManifest(
    manifestRootsOrThrow(
      `(plugin :name gl :version "1.0.0" ${COLLAPSE_SHADER_FORM} (value-kind :name shader-name :underlying symbol :cross-ref (cross-ref :target shader)))`,
    ),
  );
  const ext = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name ext :version "1.0.0" (cross-ref-provider :name uniforms) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider uniforms :target gl/shader)))',
    ),
  );
  const diags = validateCrossRefs({ plugins: [gl.plugin, ext.plugin] });
  assert.strictEqual(diags.length, 1);
  assert.strictEqual(diags[0]?.code, 'cross_ref_target_collapse');
  assert.deepStrictEqual(diags[0]?.path, ['ext', 'uniform-name', 'cross-ref']);
  assert.ok(diags[0]?.message.includes('plugin `gl`'));
});

test('collapse: a spec the registry never sees cannot collapse', () => {
  // An unresolvable `:provider` drops the cross-ref before it reaches the
  // registry, so it neither wins nor loses — one diagnostic, not two.
  const { schema } = schemaOf(
    `(plugin :name gl :version "1.0.0" ${COLLAPSE_SHADER_FORM} (value-kind :name shader-name :underlying symbol :cross-ref (cross-ref :target shader)) (value-kind :name uniform-name :underlying symbol :cross-ref (cross-ref :provider nope :target shader)))`,
  );
  assert.deepStrictEqual(
    validateCrossRefs(schema).map((d) => d.code),
    ['unknown_cross_ref_provider'],
  );
});

test('collapse: distinct targets never collapse', () => {
  const { schema } = schemaOf(
    `(plugin :name gl :version "1.0.0" ${COLLAPSE_SHADER_FORM} (form :name buffer (key :name name :type symbol :optional false) (key :name src :type string :optional false)) (cross-ref-provider :name uniforms) (value-kind :name shader-name :underlying symbol :cross-ref (cross-ref :target shader)) (value-kind :name buffer-field :underlying symbol :cross-ref (cross-ref :provider uniforms :target buffer)))`,
  );
  assert.deepStrictEqual(validateCrossRefs(schema), []);
});
