// Manifest-grammar coverage for the second-host TS loader: the packaging
// metadata keys, `:optional` defaulting, scalar-or-ref `:ref`, and the
// head-set's own count. Mirrors the field-cluster tests in
// `src/ManifestLoader.zig` so the two ports stay in lockstep.

import test from 'node:test';
import assert from 'node:assert';

import { parse } from '../src/parser.ts';
import { loadManifest } from '../src/loader.ts';
import { headSetIsUnbounded } from '../src/plugin.ts';
import { validateDocument } from '../src/Host.ts';
import type { Diagnostic } from '../src/diagnostics.ts';

function manifestRootsOrThrow(src: string) {
  const diags: Diagnostic[] = [];
  const roots = parse(src, diags);
  const parseErrs = diags.filter((d) => d.severity === 'err');
  assert.strictEqual(parseErrs.length, 0, `parse errors: ${JSON.stringify(parseErrs)}`);
  return roots;
}

test('loader: :wasm-file captured on plugin', () => {
  const r = loadManifest(
    manifestRootsOrThrow('(plugin :name x :version "1.0.0" :wasm-file "plugin.wasm")'),
  );
  assert.strictEqual(r.errors.length, 0);
  assert.strictEqual(r.plugin.wasmFile, 'plugin.wasm');
});

test('loader: well-formed :wasm-sha256 captured, no diagnostic', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name x :version "1.0.0" :wasm-sha256 "sha256-0000000000000000000000000000000000000000000000000000000000000000")',
    ),
  );
  assert.strictEqual(r.errors.length, 0);
  assert.strictEqual(r.plugin.wasmSha256?.startsWith('sha256-'), true);
  assert.strictEqual(
    r.diagnostics.find((d) => d.code === 'plugin_wasm_self_hash_malformed'),
    undefined,
  );
});

test('loader: malformed :wasm-sha256 emits plugin_wasm_self_hash_malformed', () => {
  const r = loadManifest(
    manifestRootsOrThrow('(plugin :name x :version "1.0.0" :wasm-sha256 "not-a-hash")'),
  );
  const codes = r.diagnostics.map((d) => d.code);
  assert.ok(
    codes.includes('plugin_wasm_self_hash_malformed'),
    `expected plugin_wasm_self_hash_malformed in ${JSON.stringify(codes)}`,
  );
});

test('loader: :authors accepts mixed string/symbol vector', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name x :version "1.0.0" :authors ["Ada" Babbage "Grace Hopper"])',
    ),
  );
  assert.deepStrictEqual(r.plugin.authors, ['Ada', 'Babbage', 'Grace Hopper']);
});

test('loader: canonical SPDX :license accepted without warning', () => {
  const r = loadManifest(
    manifestRootsOrThrow('(plugin :name x :version "1.0.0" :license "CC0-1.0")'),
  );
  assert.strictEqual(r.plugin.license, 'CC0-1.0');
  assert.strictEqual(
    r.diagnostics.find((d) => d.code === 'license_unrecognized'),
    undefined,
  );
});

test('loader: non-SPDX :license emits license_unrecognized warning', () => {
  const r = loadManifest(
    manifestRootsOrThrow('(plugin :name x :version "1.0.0" :license "WTFPL")'),
  );
  const d = r.diagnostics.find((x) => x.code === 'license_unrecognized');
  assert.ok(d, 'expected license_unrecognized');
  assert.strictEqual(d!.severity, 'warning');
});

test('loader: :homepage / :repository captured verbatim', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name x :version "1.0.0" :homepage "https://example.com" :repository "https://github.com/x/y")',
    ),
  );
  assert.strictEqual(r.plugin.homepage, 'https://example.com');
  assert.strictEqual(r.plugin.repository, 'https://github.com/x/y');
});

test('loader: :keywords stored as string array, in order', () => {
  const r = loadManifest(
    manifestRootsOrThrow('(plugin :name x :version "1.0.0" :keywords [graphics two-d shapes])'),
  );
  assert.deepStrictEqual(r.plugin.keywords, ['graphics', 'two-d', 'shapes']);
  assert.strictEqual(
    r.diagnostics.find((d) => d.code === 'too_many_keywords'),
    undefined,
  );
});

test('loader: >16 :keywords emits too_many_keywords warning, list still captured', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name x :version "1.0.0" :keywords [a b c d e f g h i j k l m n o p q r])',
    ),
  );
  const d = r.diagnostics.find((x) => x.code === 'too_many_keywords');
  assert.ok(d, 'expected too_many_keywords');
  assert.strictEqual(d!.severity, 'warning');
  assert.strictEqual(r.plugin.keywords.length, 18);
});

test('loader: a manifest has no format version of its own (sjon_format_unsupported retired)', () => {
  // TOMBSTONE for `sjon_format_unsupported`. Manifests once declared
  // `:sjon "<major>.<minor>"` and this loader refused a declaration above
  // its `SUPPORTED_SJON_FORMAT`. The key enabled nothing on the host
  // reading it, so the version — key, ceiling and check — was retired;
  // the code stays in the wire-stable list and is never emitted. A
  // leftover `:sjon` is an unknown top-level key: silently ignored by this
  // port's minimal meta-validation, `unknown_key` on the Zig reference.
  const r = loadManifest(manifestRootsOrThrow('(plugin :name x :version "1.0.0" :sjon "99.0")'));
  assert.strictEqual(
    r.diagnostics.find((d) => d.code === 'sjon_format_unsupported'),
    undefined,
  );
  assert.strictEqual(r.plugin.name, 'x');
});

test('loader: :version is optional — a manifest without one loads, unversioned', () => {
  // The pin target and the lockfile row, nothing else — so a manifest with
  // no version to declare declares none. Mirrors the Zig loader test.
  const r = loadManifest(
    manifestRootsOrThrow('(plugin :name x (form :name f (key :name n :type number)))'),
  );
  assert.strictEqual(r.errors.length, 0);
  assert.strictEqual(
    r.diagnostics.find((d) => d.severity === 'err'),
    undefined,
  );
  assert.strictEqual(r.plugin.name, 'x');
  assert.strictEqual(r.plugin.version, '');
  assert.strictEqual(r.plugin.forms.length, 1);
});

test('loader: a manifest with no metadata parses with empty metadata defaults', () => {
  const r = loadManifest(manifestRootsOrThrow('(plugin :name x :version "1.0.0")'));
  assert.strictEqual(r.errors.length, 0);
  assert.deepStrictEqual(r.plugin.authors, []);
  assert.strictEqual(r.plugin.license, '');
  assert.strictEqual(r.plugin.homepage, '');
  assert.strictEqual(r.plugin.repository, '');
  assert.deepStrictEqual(r.plugin.keywords, []);
  assert.strictEqual(r.plugin.wasmFile, undefined);
  assert.strictEqual(r.plugin.wasmSha256, undefined);
});

// ── `:optional` defaulting (spec §5.1) ──────────────────────────────────
//
// An unwritten `:optional` is false without a `:default` and true with one.
// This port used to hardcode `true`, so a key omitting `:optional` was
// required on Zig / Web / Rust and unrequired here. Every corpus fixture
// writes `:optional` explicitly, which is why nothing caught it.

test('loader: a key with no :optional and no :default is required', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (form :name f (key :name a :type symbol)))',
    ),
  );
  assert.strictEqual(r.plugin.forms[0]?.keys[0]?.optional, false);
});

test('loader: a key with no :optional but a :default is optional', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (form :name f (key :name a :type symbol :default x)))',
    ),
  );
  assert.strictEqual(r.plugin.forms[0]?.keys[0]?.optional, true);
});

test('loader: an explicit :optional wins over both defaults', () => {
  const both = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (form :name f (key :name a :type symbol :optional false :default x)))',
    ),
  );
  assert.strictEqual(both.plugin.forms[0]?.keys[0]?.optional, false);
  const bare = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (form :name f (key :name a :type symbol :optional true)))',
    ),
  );
  assert.strictEqual(bare.plugin.forms[0]?.keys[0]?.optional, true);
});

test('validator: an unadorned key is now reported missing, as on every other host', () => {
  const r = validateDocument(
    '(plugin :name p :version "1.0.0" (form :name f (key :name a :type symbol)))\n(f)\n',
    { projectRoot: null, resolver: null, projectFile: null },
  );
  assert.deepStrictEqual(
    r.diagnostics.filter((d) => d.severity === 'err').map((d) => d.code),
    ['missing_required_key'],
  );
});

test('loader: scalar-or-ref :ref substitutes for the default symbol', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0"' +
        ' (value-kind :name count-value :underlying number)' +
        ' (value-kind :name define-ref :underlying symbol :cross-ref (cross-ref :target define))' +
        ' (value-kind :name count :underlying scalar-or-ref' +
        ' :scalar-or-ref (scalar-or-ref-shape :base count-value :ref define-ref)))',
    ),
  );
  const alts = r.plugin.valueKinds[2]?.unionOf?.alternatives;
  assert.strictEqual(alts?.length, 2);
  assert.strictEqual(alts?.[0]?.name, 'count-value');
  // The whole feature: alternative 1 is the named kind, not `symbol`.
  assert.strictEqual(alts?.[1]?.name, 'define-ref');
});

test('loader: scalar-or-ref with no :ref still desugars to [base symbol]', () => {
  // The compatibility pin. Mirrors the Zig test of the same name; the
  // corpus case `scalar-or-ref-default-symbol` carries it cross-host.
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0"' +
        ' (value-kind :name count-value :underlying number)' +
        ' (value-kind :name count :underlying scalar-or-ref' +
        ' :scalar-or-ref (scalar-or-ref-shape :base count-value)))',
    ),
  );
  const alts = r.plugin.valueKinds[1]?.unionOf?.alternatives;
  assert.strictEqual(alts?.[1]?.name, 'symbol');
  assert.strictEqual(alts?.[1]?.namespace, null);
});

test('loader: scalar-or-ref :ref equal to :base emits invalid_manifest', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0"' +
        ' (value-kind :name count-value :underlying number)' +
        ' (value-kind :name count :underlying scalar-or-ref' +
        ' :scalar-or-ref (scalar-or-ref-shape :base count-value :ref count-value)))',
    ),
  );
  const d = r.diagnostics.find(
    (x) => x.code === 'invalid_manifest' && x.message.includes('`:ref` equal to `:base`'),
  );
  assert.ok(d, 'expected invalid_manifest for :ref == :base');
});

test('loader: scalar-or-ref :ref differing only in namespace is not a collision', () => {
  // `qualifiedRefEql` is byte-equality on both halves, matching the Zig
  // loader: a bare name and a qualified one are different refs even when
  // the namespace names this plugin.
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0"' +
        ' (value-kind :name count-value :underlying number)' +
        ' (value-kind :name count :underlying scalar-or-ref' +
        ' :scalar-or-ref (scalar-or-ref-shape :base count-value :ref p/count-value)))',
    ),
  );
  assert.strictEqual(
    r.diagnostics.find((x) => x.message.includes('`:ref` equal to `:base`')),
    undefined,
  );
});

// ── head-set aggregate counts (format 1.4) ──────────────────────────────
// `:min-children` / `:max-children` bound the whole set. Mirrors the block
// in `src/ManifestLoader_tests.zig`, including the two cross-level sums —
// the only checks in either loader that compare the two bound levels.

function headSetOf(src: string) {
  const r = loadManifest(manifestRootsOrThrow(src));
  return { r, hs: r.plugin.valueKinds[0]?.heads };
}

test('loader: set bounds ride on the compact :names spelling', () => {
  const { r, hs } = headSetOf(
    '(plugin :name p :version "1.0.0" (form :name buffer) (form :name sampler)' +
      ' (value-kind :name resource :underlying form' +
      ' :heads (head-set :names [buffer sampler] :min-children 1 :max-children 1)))',
  );
  assert.strictEqual(r.errors.length, 0);
  assert.strictEqual(hs?.heads.length, 2);
  assert.strictEqual(hs?.minChildren, 1);
  assert.strictEqual(hs?.maxChildren, 1);
  // Every head is unbounded and the set is not, so `headSetIsUnbounded`
  // has to read both levels or the count sweep never runs.
  assert.ok(hs && !headSetIsUnbounded(hs));
});

test('loader: a head-set with no set bounds leaves the pair absent', () => {
  const { r, hs } = headSetOf(
    '(plugin :name p :version "1.0.0" (form :name buffer)' +
      ' (value-kind :name resource :underlying form :heads (head-set :names [buffer])))',
  );
  assert.strictEqual(r.errors.length, 0);
  assert.strictEqual(hs?.minChildren, undefined);
  assert.strictEqual(hs?.maxChildren, undefined);
  assert.ok(hs && headSetIsUnbounded(hs));
});

test('loader: :min-children > :max-children is invalid_manifest', () => {
  const { r } = headSetOf(
    '(plugin :name p :version "1.0.0" (form :name buffer)' +
      ' (value-kind :name resource :underlying form' +
      ' :heads (head-set :names [buffer] :min-children 3 :max-children 1)))',
  );
  assert.ok(
    r.diagnostics.find(
      (d) => d.code === 'invalid_manifest' && d.message.includes('empty child range'),
    ),
  );
});

test('loader: Σ head.min above :max-children is invalid_manifest', () => {
  // The check the weaker per-head spelling would have let through:
  // neither `:min 1` exceeds `:max-children 1`, but their sum does.
  const { r } = headSetOf(
    '(plugin :name p :version "1.0.0" (form :name buffer) (form :name sampler)' +
      ' (value-kind :name resource :underlying form' +
      ' :heads (head-set :max-children 1 (head :name buffer :min 1) (head :name sampler :min 1))))',
  );
  assert.ok(
    r.diagnostics.find(
      (d) =>
        d.code === 'invalid_manifest' &&
        d.message.includes('require at least 2 child(ren) together'),
    ),
  );
});

test('loader: :min-children above Σ head.max is invalid_manifest', () => {
  const { r } = headSetOf(
    '(plugin :name p :version "1.0.0" (form :name buffer) (form :name sampler)' +
      ' (value-kind :name resource :underlying form' +
      ' :heads (head-set :min-children 3 (head :name buffer :max 1) (head :name sampler :max 1))))',
  );
  assert.ok(
    r.diagnostics.find(
      (d) =>
        d.code === 'invalid_manifest' &&
        d.message.includes('2 child(ren) its heads allow together'),
    ),
  );
});

test('loader: one unbounded head makes the Σ head.max check vacuous', () => {
  // The set is always fillable, so a high `:min-children` is satisfiable
  // and must not be refused.
  const { r } = headSetOf(
    '(plugin :name p :version "1.0.0" (form :name buffer) (form :name sampler)' +
      ' (value-kind :name resource :underlying form' +
      ' :heads (head-set :min-children 9 (head :name buffer :max 1) (head :name sampler))))',
  );
  assert.strictEqual(r.errors.length, 0);
});

test('loader: negative and fractional set counts report wrong_underlying', () => {
  const { r } = headSetOf(
    '(plugin :name p :version "1.0.0" (form :name buffer)' +
      ' (value-kind :name resource :underlying form' +
      ' :heads (head-set :names [buffer] :min-children -1 :max-children 1.5)))',
  );
  const codes = r.diagnostics.filter((d) => d.code === 'wrong_underlying').map((d) => d.message);
  assert.ok(codes.some((m) => m.includes('`:min-children` requires a non-negative integer')));
  assert.ok(codes.some((m) => m.includes('`:max-children` requires a non-negative integer')));
});

// ─── S14 — `(variant :when [a b])` ──────────────────────────────────────

test('loader: variant :when accepts a symbol or a vector, both normalised to a list', () => {
  const r = loadManifest(
    manifestRootsOrThrow(`(plugin :name p :version "1.0.0"
  (value-kind :name topo :underlying symbol
    :members (member-set :values [tri-list tri-strip line-list line-strip]))
  (form :name prim :discriminant k
    (key :name k :type topo :optional false)
    (variant :when [tri-strip line-strip] (key :name sf :type symbol :optional true))
    (variant :when line-list (key :name lw :type number :optional true))))`),
  );
  assert.strictEqual(r.errors.length, 0);
  const variants = r.plugin.forms[0]?.variants ?? [];
  assert.deepStrictEqual(
    variants.map((v) => v.when),
    [['tri-strip', 'line-strip'], ['line-list']],
  );
});

test('loader: the three :when list refusals are invalid_manifest, once per finding', () => {
  const r = loadManifest(
    manifestRootsOrThrow(`(plugin :name p :version "1.0.0"
  (value-kind :name tag :underlying symbol :members (member-set :values [a b c]))
  (form :name f :discriminant k
    (key :name k :type tag :optional false)
    (variant :when [] (key :name x :type number :optional true))
    (variant :when [a b a] (key :name y :type number :optional true))
    (variant :when [b c] (key :name z :type number :optional true))
    (variant :when b (key :name w :type number :optional true))))`),
  );
  const msgs = r.diagnostics.filter((d) => d.code === 'invalid_manifest').map((d) => d.message);
  assert.strictEqual(msgs.length, 4, JSON.stringify(msgs));
  assert.ok(msgs.some((m) => m.includes('`:when []`')));
  assert.ok(msgs.some((m) => m.includes('lists `a` twice')));
  assert.ok(
    msgs.some((m) =>
      m.includes('`:when [b c]` lists `b`, already selected by variant `:when [a b a]`'),
    ),
  );
  assert.ok(
    msgs.some((m) =>
      m.includes('`:when b` lists `b`, already selected by variant `:when [a b a]`'),
    ),
  );
});

test('loader: two :when-less variants are not "a value listed twice"', () => {
  // A `:when`-less variant carries an unnameable placeholder that selects
  // nothing (the Zig meta-validator already reports it missing); two of
  // them must not add an "already selected" finding on top.
  const r = loadManifest(
    manifestRootsOrThrow(`(plugin :name p :version "1.0.0"
  (value-kind :name tag :underlying symbol :members (member-set :values [a b]))
  (form :name f :discriminant k
    (key :name k :type tag :optional false)
    (variant (key :name x :type number :optional true))
    (variant (key :name y :type number :optional true))))`),
  );
  assert.strictEqual(r.diagnostics.filter((d) => d.message.includes('already selected')).length, 0);
});
