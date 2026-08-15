// Discriminant / variant / exclusive-group coverage for the second-host TS
// port. These three features were declared gaps in the conformance skip
// list for a long time; the corpus is the real gate now that the families
// run, but the corpus reaches the *loader* only through whole documents.
// The tests here pin the loader half directly — what gets stored, and which
// malformed declaration produces which code — so a regression in parsing
// surfaces as a named failure rather than as twelve corpus diffs.

import test from 'node:test';
import assert from 'node:assert';

import { parse } from '../src/parser.ts';
import { loadManifest } from '../src/loader.ts';
import { validateDocument } from '../src/Host.ts';
import type { Diagnostic } from '../src/diagnostics.ts';

function manifestRootsOrThrow(src: string) {
  const diags: Diagnostic[] = [];
  const roots = parse(src, diags);
  const parseErrs = diags.filter((d) => d.severity === 'err');
  assert.strictEqual(parseErrs.length, 0, `parse errors: ${JSON.stringify(parseErrs)}`);
  return roots;
}

const DISCRIMINATED = `
(plugin :name probe :version "1.0.0"
  (value-kind :name kind-tag
    :underlying symbol
    :members (member-set :values [kick bass]))
  (form :name track
    :discriminant kind
    (key :name kind :type kind-tag :optional true)
    (variant :when kick
      (key :name step :type number :optional true))
    (variant :when bass
      (key :name sequence :type any :optional true))))
`;

test('loader: :discriminant resolves to an index into keys', () => {
  const r = loadManifest(manifestRootsOrThrow(DISCRIMINATED));
  assert.strictEqual(r.errors.length, 0);
  const form = r.plugin.forms.find((f) => f.name === 'track');
  assert.ok(form, 'expected a `track` form');
  assert.strictEqual(form.discriminantName, 'kind');
  assert.strictEqual(form.discriminantIdx, 0);
  assert.strictEqual(r.diagnostics.length, 0);
});

test('loader: every (variant …) is captured with its own keys', () => {
  const r = loadManifest(manifestRootsOrThrow(DISCRIMINATED));
  const form = r.plugin.forms.find((f) => f.name === 'track');
  assert.ok(form?.variants, 'expected variants');
  assert.deepStrictEqual(
    form.variants.map((v) => v.when),
    ['kick', 'bass'],
  );
  assert.deepStrictEqual(
    form.variants.map((v) => v.keys.map((k) => k.name)),
    [['step'], ['sequence']],
  );
});

test('loader: a :discriminant naming no declared key is unknown_key', () => {
  const r = loadManifest(
    manifestRootsOrThrow(`
(plugin :name probe :version "1.0.0"
  (form :name track
    :discriminant nope
    (key :name kind :type symbol :optional true)))
`),
  );
  const d = r.diagnostics.find((x) => x.code === 'unknown_key');
  assert.ok(d, `expected unknown_key in ${JSON.stringify(r.diagnostics.map((x) => x.code))}`);
  assert.deepStrictEqual(d.path, ['track', 'discriminant']);
  // The name is still carried for diagnostics, but no index was resolved —
  // downstream code must not be able to reach past `keys`.
  const form = r.plugin.forms.find((f) => f.name === 'track');
  assert.strictEqual(form?.discriminantName, 'nope');
  assert.strictEqual(form?.discriminantIdx, undefined);
});

const ROUTES = (group: string) => `
(plugin :name routes :version "1.0.0"
  (form :name route
    (key :name from :type symbol :optional true)
    (key :name to :type symbol :optional true)
    (key :name at :type symbol :optional true)
    ${group}))
`;

test('loader: a well-formed exclusive-group is stored with its cardinality', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      ROUTES(`(exclusive-group :cardinality at-most-one
      (alt :keys [from to])
      (alt :keys [at]))`),
    ),
  );
  assert.strictEqual(r.diagnostics.length, 0);
  const form = r.plugin.forms.find((f) => f.name === 'route');
  assert.ok(form?.exclusiveGroups, 'expected exclusiveGroups');
  assert.strictEqual(form.exclusiveGroups.length, 1);
  assert.strictEqual(form.exclusiveGroups[0]?.cardinality, 'at_most_one');
  assert.deepStrictEqual(
    form.exclusiveGroups[0]?.alternatives.map((a) => a.keys),
    [['from', 'to'], ['at']],
  );
});

test('loader: an unrecognised :cardinality falls back to exactly-one', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      ROUTES(`(exclusive-group :cardinality wat
      (alt :keys [from])
      (alt :keys [at]))`),
    ),
  );
  const form = r.plugin.forms.find((f) => f.name === 'route');
  assert.strictEqual(form?.exclusiveGroups?.[0]?.cardinality, 'exactly_one');
});

test('loader: a one-alternative group is exclusive_group_invalid', () => {
  const r = loadManifest(manifestRootsOrThrow(ROUTES('(exclusive-group (alt :keys [from]))')));
  const d = r.diagnostics.find((x) => x.code === 'exclusive_group_invalid');
  assert.ok(d, `expected exclusive_group_invalid in ${JSON.stringify(r.diagnostics)}`);
  assert.deepStrictEqual(d.path, ['route', 'exclusive-group']);
  assert.match(d.message, /needs at least 2 alternatives/);
});

test('loader: an alt naming an undeclared key is exclusive_group_invalid', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      ROUTES(`(exclusive-group
      (alt :keys [from])
      (alt :keys [nope]))`),
    ),
  );
  const d = r.diagnostics.find((x) => x.code === 'exclusive_group_invalid');
  assert.ok(d, 'expected exclusive_group_invalid');
  assert.match(d.message, /alt names `nope` but no such key is declared/);
});

test('loader: one key in two alts of the same group is a bundle collision', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      ROUTES(`(exclusive-group
      (alt :keys [from to])
      (alt :keys [from at]))`),
    ),
  );
  const codes = r.diagnostics.map((x) => x.code);
  assert.ok(
    codes.includes('exclusive_bundle_collision'),
    `expected exclusive_bundle_collision in ${JSON.stringify(codes)}`,
  );
  // In-group repeat reports once, as the bundle collision — the cross-group
  // `exclusive_group_invalid` is suppressed for the same key.
  assert.strictEqual(codes.filter((c) => c === 'exclusive_group_invalid').length, 0);
});

test('loader: one key in two different groups is exclusive_group_invalid', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      ROUTES(`(exclusive-group
      (alt :keys [from])
      (alt :keys [to]))
    (exclusive-group
      (alt :keys [from])
      (alt :keys [at]))`),
    ),
  );
  const d = r.diagnostics.find((x) => x.code === 'exclusive_group_invalid');
  assert.ok(d, 'expected exclusive_group_invalid');
  assert.match(d.message, /`from` appears in more than one exclusive-group/);
});

test('loader: an exclusive-group naming the discriminant is invalid', () => {
  const r = loadManifest(
    manifestRootsOrThrow(`
(plugin :name probe :version "1.0.0"
  (form :name track
    :discriminant kind
    (key :name kind :type symbol :optional true)
    (key :name step :type number :optional true)
    (exclusive-group
      (alt :keys [kind])
      (alt :keys [step]))))
`),
  );
  const d = r.diagnostics.find((x) => x.code === 'exclusive_group_invalid');
  assert.ok(d, 'expected exclusive_group_invalid');
  assert.match(d.message, /must not name discriminant `:kind`/);
});

test('loader: a variant-scoped group is pathed through its :when', () => {
  const r = loadManifest(
    manifestRootsOrThrow(`
(plugin :name probe :version "1.0.0"
  (form :name track
    :discriminant kind
    (key :name kind :type symbol :optional true)
    (variant :when kick
      (key :name step :type number :optional true)
      (exclusive-group (alt :keys [step])))))
`),
  );
  const d = r.diagnostics.find((x) => x.code === 'exclusive_group_invalid');
  assert.ok(d, 'expected exclusive_group_invalid');
  assert.deepStrictEqual(d.path, ['track', 'kick', 'exclusive-group']);
  assert.match(d.message, /form `track` \(variant `:when kick`\)/);
});

test('loader: a variant declares its groups against its own keys', () => {
  const r = loadManifest(
    manifestRootsOrThrow(`
(plugin :name probe :version "1.0.0"
  (form :name track
    :discriminant kind
    (key :name kind :type symbol :optional true)
    (variant :when kick
      (key :name step :type number :optional true)
      (key :name sweep :type number :optional true)
      (exclusive-group
        (alt :keys [step])
        (alt :keys [sweep])))))
`),
  );
  assert.strictEqual(r.diagnostics.length, 0);
  const v = r.plugin.forms.find((f) => f.name === 'track')?.variants?.[0];
  assert.strictEqual(v?.exclusiveGroups?.length, 1);
  assert.deepStrictEqual(
    v.exclusiveGroups[0]?.alternatives.map((a) => a.keys),
    [['step'], ['sweep']],
  );
});

test('loader: an undiscriminated, ungrouped form carries none of the four fields', () => {
  const r = loadManifest(
    manifestRootsOrThrow(
      '(plugin :name p :version "1.0.0" (form :name f (key :name a :type symbol)))',
    ),
  );
  const form = r.plugin.forms[0];
  assert.strictEqual(form?.discriminantName, undefined);
  assert.strictEqual(form?.discriminantIdx, undefined);
  assert.strictEqual(form?.variants, undefined);
  assert.strictEqual(form?.exclusiveGroups, undefined);
});

// ── Validator half ──────────────────────────────────────────────────────
//
// The corpus covers what a document *is* checked for; these pin the rules
// it does not reach — the discriminant-first position rule, the variant
// required-key sweep, and which of the two `unknown_key` messages fires.

const TRACK_SCHEMA = `
(plugin :name probe :version "1.0.0"
  (value-kind :name kind-tag
    :underlying symbol
    :members (member-set :values [kick bass]))
  (form :name track
    :discriminant kind
    (key :name kind :type kind-tag :optional true)
    (variant :when kick
      (key :name step :type number :optional false))
    (variant :when bass
      (key :name sequence :type any :optional true))))
`;

function validateTrack(doc: string) {
  const r = validateDocument(`${TRACK_SCHEMA}\n${doc}\n`, {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  return r.diagnostics.filter((d) => d.severity === 'err');
}

test('validator: a variant-only key is accepted once the discriminant is set', () => {
  assert.deepStrictEqual(
    validateTrack('(track :kind kick :step 4)').map((d) => d.code),
    [],
  );
});

test('validator: a variant-only key of the *other* variant is unknown', () => {
  const errs = validateTrack('(track :kind kick :sequence [1])');
  assert.deepStrictEqual(
    errs.map((d) => d.code),
    ['unknown_key', 'missing_required_key'],
  );
  // With a variant resolved, the message names it rather than hinting at
  // ordering — the discriminant is not the problem here.
  assert.match(errs[0]!.message, /in form `track` \(variant `:when kick`\)/);
});

test('validator: a variant-only key before the discriminant is unknown, with the ordering hint', () => {
  const errs = validateTrack('(track :step 4 :kind kick)');
  assert.deepStrictEqual(
    errs.map((d) => d.code),
    ['unknown_key'],
  );
  assert.match(errs[0]!.message, /`:kind` must be set before variant-only keys/);
  // …and the variant required sweep does NOT then also report `:step`
  // missing: the author wrote it, just too early.
});

test('validator: an unset required variant key is reported against its :when', () => {
  const errs = validateTrack('(track :kind kick)');
  assert.deepStrictEqual(
    errs.map((d) => d.code),
    ['missing_required_key'],
  );
  assert.match(errs[0]!.message, /\(variant `:when kick`\) is missing required keyword `:step`/);
});

test('validator: a discriminant value outside the enum resolves no variant', () => {
  const errs = validateTrack('(track :kind bogus :step 4)');
  // `not_member` from the type check, then `:step` is unknown because no
  // variant was selected — not silently accepted against `kick`.
  assert.deepStrictEqual(
    errs.map((d) => d.code),
    ['not_member', 'unknown_key'],
  );
});

test('validator: an undiscriminated form still reports plain unknown keys', () => {
  const r = validateDocument(
    `(plugin :name p :version "1.0.0" (form :name f (key :name a :type symbol :optional true)))
(f :b x)
`,
    { projectRoot: null, resolver: null, projectFile: null },
  );
  const errs = r.diagnostics.filter((d) => d.severity === 'err');
  assert.deepStrictEqual(
    errs.map((d) => d.code),
    ['unknown_key'],
  );
  assert.strictEqual(errs[0]!.message, 'unknown keyword `:b` in form `f`');
});

test('validator: an open discriminated form skips every shape check', () => {
  const r = validateDocument(
    `(plugin :name probe :version "1.0.0"
  (value-kind :name kind-tag :underlying symbol :members (member-set :values [kick]))
  (form :name track :open true
    :discriminant kind
    (key :name kind :type kind-tag :optional true)
    (variant :when kick (key :name step :type number :optional false))))
(track :whatever 1)
`,
    { projectRoot: null, resolver: null, projectFile: null },
  );
  // No `missing_discriminant_key`, no `unknown_key`, no variant sweep.
  assert.deepStrictEqual(
    r.diagnostics.filter((d) => d.severity === 'err').map((d) => d.code),
    [],
  );
});

// ── Exclusive-group runtime ─────────────────────────────────────────────
//
// The corpus covers the seven form-scoped shapes; these pin what it does
// not reach — the at-most-one negative, a group on a variant, and the two
// ways a group takes over presence reporting from the required sweep.

function validateSrc(src: string) {
  return validateDocument(src, {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  }).diagnostics.filter((d) => d.severity === 'err');
}

const ROUTE_GROUP = (cardinality: string, extra = '') => `
(plugin :name routes :version "1.0.0"
  (form :name route
    (key :name from :type symbol :optional true)
    (key :name to :type symbol :optional true)
    (key :name at :type symbol :optional true)
    ${extra}
    (exclusive-group :cardinality ${cardinality}
      (alt :keys [from to])
      (alt :keys [at]))))
`;

test('validator: at-most-one still rejects two present alternatives', () => {
  const errs = validateSrc(`${ROUTE_GROUP('at-most-one')}\n(route :from a :to b :at c)\n`);
  assert.deepStrictEqual(
    errs.map((d) => d.code),
    ['mutually_exclusive_keys_present'],
  );
  assert.strictEqual(
    errs[0]!.message,
    'form `route`: at most one of :from+:to | :at may be present',
  );
});

test('validator: at-most-one accepts no alternative at all', () => {
  assert.deepStrictEqual(validateSrc(`${ROUTE_GROUP('at-most-one')}\n(route)\n`), []);
});

test('validator: exactly-one names both alternatives when none is present', () => {
  const errs = validateSrc(`${ROUTE_GROUP('exactly-one')}\n(route)\n`);
  assert.strictEqual(
    errs[0]!.message,
    'form `route`: exactly one of :from+:to | :at must be present',
  );
});

test('validator: a partial bundle names which sibling is missing', () => {
  const errs = validateSrc(`${ROUTE_GROUP('exactly-one')}\n(route :from a)\n`);
  // …and suppresses `required_one_of_missing`: the author did choose an
  // alternative, so pointing at the gap beats saying they chose none.
  assert.deepStrictEqual(
    errs.map((d) => d.code),
    ['exclusive_bundle_partial'],
  );
  assert.strictEqual(
    errs[0]!.message,
    'form `route`: exclusive-group alt `:from+:to` is partially present (:from set, :to missing); bundles are all-or-nothing',
  );
});

test('validator: a partial bundle beside a satisfied sibling is not reported', () => {
  // `:at` fully wins the group, so `:from` alone is overspecification the
  // presence count already covers — not a broken bundle.
  assert.deepStrictEqual(validateSrc(`${ROUTE_GROUP('at-most-one')}\n(route :at c :from a)\n`), []);
});

test('validator: a required grouped key is not also reported as missing', () => {
  // `:from` / `:to` / `:at` are `:optional false` here, yet a document
  // choosing `:at` is clean: the group says "one of", and a per-key
  // "missing" on the other two would contradict it.
  const src = `
(plugin :name routes :version "1.0.0"
  (form :name route
    (key :name from :type symbol :optional false)
    (key :name to :type symbol :optional false)
    (key :name at :type symbol :optional false)
    (exclusive-group :cardinality exactly-one
      (alt :keys [from to])
      (alt :keys [at]))))

(route :at c)
`;
  assert.deepStrictEqual(validateSrc(src), []);
});

test('validator: a variant-scoped group runs against the active variant', () => {
  const src = `
(plugin :name probe :version "1.0.0"
  (value-kind :name kind-tag
    :underlying symbol
    :members (member-set :values [kick bass]))
  (form :name track
    :discriminant kind
    (key :name kind :type kind-tag :optional true)
    (variant :when kick
      (key :name step :type number :optional true)
      (key :name sweep :type number :optional true)
      (exclusive-group :cardinality exactly-one
        (alt :keys [step])
        (alt :keys [sweep])))
    (variant :when bass
      (key :name sequence :type any :optional true))))
`;
  // Group unsatisfied under `kick`…
  const missing = validateSrc(`${src}\n(track :kind kick)\n`);
  assert.deepStrictEqual(
    missing.map((d) => d.code),
    ['required_one_of_missing'],
  );
  assert.strictEqual(
    missing[0]!.message,
    'form `track` (variant `:when kick`): exactly one of :step | :sweep must be present',
  );
  // …both present is the other failure…
  assert.deepStrictEqual(
    validateSrc(`${src}\n(track :kind kick :step 1 :sweep 2)\n`).map((d) => d.code),
    ['mutually_exclusive_keys_present'],
  );
  // …one present is clean, and the group does not apply to `bass` at all.
  assert.deepStrictEqual(validateSrc(`${src}\n(track :kind kick :step 1)\n`), []);
  assert.deepStrictEqual(validateSrc(`${src}\n(track :kind bass)\n`), []);
});
