// Strict compile matrix for the structural exclusive-group emission
// (Task 5). Type-level consumers over committed copies of the
// Zig-emitted `.d.ts` goldens (`../golden/*.d.ts`, kept byte-identical
// to `examples/plugins/*/[name].d.ts.golden` by schemaExport.test.ts —
// and those goldens byte-identical to this host's emitter by the parity
// tests in the same file).
//
// Checked two ways: by the package `tsc --noEmit` (this file is in the
// include set, with `exactOptionalPropertyTypes` ON) and by
// `npm run typecheck:matrix`'s second leg
// (`test/typecheck/tsconfig.exact-off.json`, with the option OFF).
//
// Every "must compile" value is a document the SJON runtime validator
// accepts: each complete alternative alone, a complete alternative
// beside a merely partial competitor (the distributive `_SjonNotAll`
// unions forbid only whole competing bundles), the `at-most-one`
// none-arm, and the valid cross-product of two enforced groups.
// Every "must fail" value is a document the validator rejects — the
// assignment carries a single `@ts-expect-error` whose comment names
// the rule. Must-fail documents are built as plain variables and then
// assigned, so each rejection is a genuine assignability conflict, not
// object-literal excess-property noise, and the diagnostic lands on
// the one annotated assignment line.
//
// It is NOT a `.test.ts`, so the node:test glob never runs it.

import type { GroupFrame_Frame } from '../golden/group-frame.d.ts';
import type {
  GroupLocal_Canvas,
  GroupLocal_Board,
  GroupLocal_Shelf,
} from '../golden/group-local.d.ts';
import type { GroupMixed_Mixed } from '../golden/group-mixed.d.ts';
import type { GroupOpen_Page } from '../golden/group-open.d.ts';
import type { GroupPair_Pair } from '../golden/group-pair.d.ts';
import type { GroupThree_Choice } from '../golden/group-three.d.ts';
import type { GroupRequired_Req, GroupRequired_Either } from '../golden/group-required.d.ts';
import type { SjonNotAll } from '../golden/not-all.d.ts';
import type { GroupUnits_Span } from '../golden/group-units.d.ts';
import type { GroupVariantPair_Track } from '../golden/group-variant-pair.d.ts';
import type { LocalForms_Canvas } from '../golden/local-forms.d.ts';
import type { SjonXkey, Xkey_Route, Xkey_Tag } from '../golden/xkey.d.ts';

// ── exactly-one [a | b1 + b2 | c] — GroupThree_Choice ──────────────────────

// Must compile: each complete alternative alone.
const threeA: GroupThree_Choice = { $form: 'choice', $ns: 'group-three', a: 'x' } as const;
const threeBC: GroupThree_Choice = { $form: 'choice', $ns: 'group-three', b1: 'y', b2: 1 } as const;
const threeC: GroupThree_Choice = { $form: 'choice', $ns: 'group-three', c: true } as const;

// Must compile: a complete alternative beside a partial competitor
// (`a` complete; `b1` without `b2` is not a whole competing bundle).
// Built as a variable: the check is *assignability*, which the SJON
// semantics require — a fresh literal would trip per-union-member
// excess-property checking instead.
const threeABesidePartialDoc = { $form: 'choice', $ns: 'group-three', a: 'x', b1: 'y' } as const;
const threeABesidePartial: GroupThree_Choice = threeABesidePartialDoc;

// Must fail: two complete alternatives (`a` + `c`).
const threeTwoCompleteDoc = { $form: 'choice', $ns: 'group-three', a: 'x', c: true } as const;
// @ts-expect-error two complete alternatives — exactly-one [a | b1 + b2 | c]
const threeTwoComplete: GroupThree_Choice = threeTwoCompleteDoc;

// Must fail: neither present.
const threeNeitherDoc = { $form: 'choice', $ns: 'group-three' } as const;
// @ts-expect-error neither present — exactly-one [a | b1 + b2 | c]
const threeNeither: GroupThree_Choice = threeNeitherDoc;

// Must fail: a lone partial bundle (`b1` without `b2`, nothing else).
const threeLonePartialDoc = { $form: 'choice', $ns: 'group-three', b1: 'y' } as const;
// @ts-expect-error lone partial bundle — b1 without b2 satisfies no alternative
const threeLonePartial: GroupThree_Choice = threeLonePartialDoc;

// Must fail: the flattened-helper case — `a` beside a *complete*
// `(b1 + b2)` sibling. One `_SjonNotAll` per competitor rejects this; a
// single flattened helper over every competitor key would accept it
// through whichever slot happens to be absent (`c` here).
const threeFlattenedDoc = { $form: 'choice', $ns: 'group-three', a: 'x', b1: 'y', b2: 1 } as const;
// @ts-expect-error flattened-helper — a + (b1 + b2) is two complete alternatives
const threeFlattened: GroupThree_Choice = threeFlattenedDoc;

// ── at-most-one [prefix + suffix | literal] — Xkey_Tag ─────────────────────

// Must compile: the none-arm — no grouped key at all.
const tagNone: Xkey_Tag = { $form: 'tag', $ns: 'xkey', name: { $sym: 'badge' } } as const;

// Must compile: each complete alternative alone.
const tagFlank: Xkey_Tag = {
  $form: 'tag',
  $ns: 'xkey',
  name: { $sym: 'badge' },
  prefix: 'pre-',
  suffix: '-post',
} as const;
const tagLiteral: Xkey_Tag = {
  $form: 'tag',
  $ns: 'xkey',
  name: { $sym: 'badge' },
  literal: 'static',
} as const;

// Must compile: a complete alternative beside a partial competitor
// (`literal` complete; `prefix` without `suffix` is not a whole bundle).
// Variable form — see the note on `threeABesidePartial`.
const tagLiteralBesidePartialDoc = {
  $form: 'tag',
  $ns: 'xkey',
  name: { $sym: 'badge' },
  literal: 'static',
  prefix: 'pre-',
} as const;
const tagLiteralBesidePartial: Xkey_Tag = tagLiteralBesidePartialDoc;

// Must fail: a lone partial bundle (`prefix` without `suffix`, no `literal`).
const tagLonePartialDoc = {
  $form: 'tag',
  $ns: 'xkey',
  name: { $sym: 'badge' },
  prefix: 'pre-',
} as const;
// @ts-expect-error lone partial bundle — prefix without suffix is no alternative
const tagLonePartial: Xkey_Tag = tagLonePartialDoc;

// Must fail: two complete alternatives (`prefix + suffix` and `literal`).
const tagBothCompleteDoc = {
  $form: 'tag',
  $ns: 'xkey',
  name: { $sym: 'badge' },
  prefix: 'pre-',
  suffix: '-post',
  literal: 'static',
} as const;
// @ts-expect-error two complete alternatives — at-most-one [prefix + suffix, literal]
const tagBothComplete: Xkey_Tag = tagBothCompleteDoc;

// ── exactly-one [from + to | at] — Xkey_Route ──────────────────────────────

// Must compile: each complete alternative alone.
const routeEndpoints: Xkey_Route = {
  $form: 'route',
  $ns: 'xkey',
  name: { $sym: 'path' },
  from: { $sym: 'a' },
  to: { $sym: 'b' },
} as const;
const routeAt: Xkey_Route = {
  $form: 'route',
  $ns: 'xkey',
  name: { $sym: 'path' },
  at: { $sym: 'c' },
} as const;

// Must compile: a complete alternative beside a partial competitor
// (`at` complete; `from` without `to` is not a whole bundle) — the
// validator's `exclusive_bundle_partial`-beside-clean distinction.
// Variable form — see the note on `threeABesidePartial`.
const routeAtBesidePartialDoc = {
  $form: 'route',
  $ns: 'xkey',
  name: { $sym: 'path' },
  at: { $sym: 'c' },
  from: { $sym: 'a' },
} as const;
const routeAtBesidePartial: Xkey_Route = routeAtBesidePartialDoc;

// Must fail: a lone partial bundle (`from` without `to`).
const routeLoneFromDoc = {
  $form: 'route',
  $ns: 'xkey',
  name: { $sym: 'path' },
  from: { $sym: 'a' },
} as const;
// @ts-expect-error lone partial bundle — from without to is no alternative
const routeLoneFrom: Xkey_Route = routeLoneFromDoc;

// Must fail: two complete alternatives (`from + to` and `at`).
const routeAllThreeDoc = {
  $form: 'route',
  $ns: 'xkey',
  name: { $sym: 'path' },
  from: { $sym: 'a' },
  to: { $sym: 'b' },
  at: { $sym: 'c' },
} as const;
// @ts-expect-error two complete alternatives — exactly-one [from + to, at]
const routeAllThree: Xkey_Route = routeAllThreeDoc;

// The barrel export stays a usable union of the plugin's forms.
const xkeyBarrel: SjonXkey = routeAt;
const xkeyBarrelTag: SjonXkey = tagLiteral;

// ── required base key beside exactly-one arms — GroupRequired_Req ──────────

// Must compile: the ungrouped required key `keep` beside either arm.
const reqA: GroupRequired_Req = { $form: 'req', $ns: 'group-required', keep: 'k', a: 1 } as const;
const reqB: GroupRequired_Req = { $form: 'req', $ns: 'group-required', keep: 'k', b: 2 } as const;

// Must fail: two complete alternatives (`a` and `b`).
const reqBothDoc = { $form: 'req', $ns: 'group-required', keep: 'k', a: 1, b: 2 } as const;
// @ts-expect-error two complete alternatives — exactly-one [a, b]
const reqBoth: GroupRequired_Req = reqBothDoc;

// ── two enforced groups in one form — GroupPair_Pair ───────────────────────
// exactly-one [a | b] composed with at-most-one [c | d]; the valid
// cross-product of the two groups must all compile.

const pairA: GroupPair_Pair = { $form: 'pair', $ns: 'group-pair', a: 'x' } as const;
const pairB: GroupPair_Pair = { $form: 'pair', $ns: 'group-pair', b: 'y' } as const;
const pairAC: GroupPair_Pair = { $form: 'pair', $ns: 'group-pair', a: 'x', c: 1 } as const;
const pairAD: GroupPair_Pair = { $form: 'pair', $ns: 'group-pair', a: 'x', d: 2 } as const;
const pairBC: GroupPair_Pair = { $form: 'pair', $ns: 'group-pair', b: 'y', c: 1 } as const;
const pairBD: GroupPair_Pair = { $form: 'pair', $ns: 'group-pair', b: 'y', d: 2 } as const;

// Must fail: two complete alternatives in the first group (`a` + `b`)
// even though the second group sits at its none-arm — the second
// group's intersection must not weaken the first.
const pairBothFirstDoc = { $form: 'pair', $ns: 'group-pair', a: 'x', b: 'y' } as const;
// @ts-expect-error two complete alternatives — exactly-one [a, b] beside group [c, d]
const pairBothFirst: GroupPair_Pair = pairBothFirstDoc;

// Must fail: two complete alternatives in the second group (`c` + `d`)
// beside a satisfied first — the first must not weaken the second.
const pairBothSecondDoc = { $form: 'pair', $ns: 'group-pair', a: 'x', c: 1, d: 2 } as const;
// @ts-expect-error two complete alternatives — at-most-one [c, d] beside group [a, b]
const pairBothSecond: GroupPair_Pair = pairBothSecondDoc;

// ── two enforced groups on ONE VARIANT — GroupVariantPair_Track ────────────
// The `kick` branch carries exactly-one [step, sweep] composed with
// at-most-one [gate, pass]; the valid cross-product must compile, and a
// violation in either group must fail while the other sits satisfied.
// The `bass` branch has no groups, proving the constraint is
// branch-local.

// Must compile: the valid cross-product of the two groups.
const vpStepNone: GroupVariantPair_Track = {
  $form: 'track',
  $ns: 'group-variant-pair',
  kind: { $sym: 'kick' },
  step: 1,
} as const;
const vpSweepNone: GroupVariantPair_Track = {
  $form: 'track',
  $ns: 'group-variant-pair',
  kind: { $sym: 'kick' },
  sweep: 2,
} as const;
const vpStepGate: GroupVariantPair_Track = {
  $form: 'track',
  $ns: 'group-variant-pair',
  kind: { $sym: 'kick' },
  step: 1,
  gate: 'g',
} as const;
const vpStepPass: GroupVariantPair_Track = {
  $form: 'track',
  $ns: 'group-variant-pair',
  kind: { $sym: 'kick' },
  step: 1,
  pass: 'p',
} as const;

// Must compile: the at-most-one none-arm — no grouped key of the second
// group while the first sits satisfied.
const vpSweepNoneArm: GroupVariantPair_Track = {
  $form: 'track',
  $ns: 'group-variant-pair',
  kind: { $sym: 'kick' },
  sweep: 2,
} as const;

// Must compile: the group-free `bass` branch is untouched by the kick
// groups (branch-local scoping).
const vpBass: GroupVariantPair_Track = {
  $form: 'track',
  $ns: 'group-variant-pair',
  kind: { $sym: 'bass' },
  sequence: [1, 2],
} as const;

// Must fail: neither alternative of the first group.
const vpNeitherFirstDoc = {
  $form: 'track',
  $ns: 'group-variant-pair',
  kind: { $sym: 'kick' },
  gate: 'g',
} as const;
// @ts-expect-error neither present — exactly-one [step, sweep] on the kick branch
const vpNeitherFirst: GroupVariantPair_Track = vpNeitherFirstDoc;

// Must fail: two complete alternatives in the first group while the
// second sits at its none-arm.
const vpBothFirstDoc = {
  $form: 'track',
  $ns: 'group-variant-pair',
  kind: { $sym: 'kick' },
  step: 1,
  sweep: 2,
} as const;
// @ts-expect-error two complete alternatives — exactly-one [step, sweep] beside at-most-one [gate, pass]
const vpBothFirst: GroupVariantPair_Track = vpBothFirstDoc;

// Must fail: two complete alternatives in the second group while the
// first sits satisfied.
const vpBothSecondDoc = {
  $form: 'track',
  $ns: 'group-variant-pair',
  kind: { $sym: 'kick' },
  step: 1,
  gate: 'g',
  pass: 'p',
} as const;
// @ts-expect-error two complete alternatives — at-most-one [gate, pass] beside exactly-one [step, sweep]
const vpBothSecond: GroupVariantPair_Track = vpBothSecondDoc;

// ── a slot-local enforced group — GroupLocal_Canvas.wrap ───────────────────
// The local `inner` carries exactly-one [a, b]. The fallback enumerates:
// every arm names a global head, unqualified or `$ns`-qualified, so a
// value whose head names the local has no arm left when it violates the
// group — including when it arrives through a variable, a function
// parameter, or `JSON.parse`, where TypeScript's excess-property
// checking (fresh object literals only) never fires (branch review §2,
// rework round 2: the old `{ readonly $form: string; readonly $ns:
// string }` qualified-any arm admitted exactly those).

// Must compile: each complete alternative alone, with the ungrouped tag.
const glA: GroupLocal_Canvas = {
  $form: 'canvas',
  $ns: 'group-local',
  wrap: { $form: 'inner', tag: 't', a: 1 },
} as const;
const glB: GroupLocal_Canvas = {
  $form: 'canvas',
  $ns: 'group-local',
  wrap: { $form: 'inner', b: 2 },
} as const;

// Must compile: a valid single-alternative value through a variable —
// the same path the reds below take, so the rejection is the group's,
// not the variable's.
const glVarSingleDoc = { $form: 'inner' as const, $ns: 'group-local', a: 1 };
const glVarSingle: GroupLocal_Canvas = {
  $form: 'canvas',
  $ns: 'group-local',
  wrap: glVarSingleDoc,
};

// Must compile: the additive global fallback — an unqualified global by
// name, and a qualified global (a `$ns` head bypasses locals and
// resolves against the plugin catalog). Built as variables: the check is
// assignability, not fresh-literal excess-property luck.
const glGlobal: GroupLocal_Canvas = {
  $form: 'canvas',
  $ns: 'group-local',
  wrap: { $form: 'canvas' },
} as const;
const glVarBareGlobalDoc = { $form: 'canvas' as const };
const glVarBareGlobal: GroupLocal_Canvas = {
  $form: 'canvas',
  $ns: 'group-local',
  wrap: glVarBareGlobalDoc,
};
const glVarQualifiedDoc = { $form: 'canvas' as const, $ns: 'group-local' };
const glVarQualified: GroupLocal_Canvas = {
  $form: 'canvas',
  $ns: 'group-local',
  wrap: glVarQualifiedDoc,
};

// Must fail: the branch-review acceptance repro, verbatim — both
// alternatives through a variable. `tsc` exited 0 on this before the
// fallback enumerated; it must be TS2322 now.
const viaVar = { $form: 'inner' as const, $ns: 'group-local', a: 1, b: 2 };
// @ts-expect-error variable path — both alternatives on the local `inner` must not reach a fallback arm
const canvas: GroupLocal_Canvas = { $form: 'canvas', $ns: 'group-local', wrap: viaVar };

// Must fail: neither alternative through a variable. The directive sits
// on the `wrap` line — where `tsc` reports the assignability conflict on
// a wrapped statement.
const glVarNeitherDoc = { $form: 'inner' as const, $ns: 'group-local', tag: 't' };
const glVarNeither: GroupLocal_Canvas = {
  $form: 'canvas',
  $ns: 'group-local',
  // @ts-expect-error variable path — neither alternative on the local `inner` must not reach a fallback arm
  wrap: glVarNeitherDoc,
};

// Must fail: the same both-alternatives value through a function
// parameter (the parameter's type is the violating local shape; the
// rejection lands on the return's `wrap` assignment).
const glParamDoc = { $form: 'inner' as const, $ns: 'group-local', a: 1, b: 2 };
function glTakeWrap(wrap: typeof glParamDoc): GroupLocal_Canvas {
  // @ts-expect-error function-parameter path — both alternatives have no arm left
  return { $form: 'canvas', $ns: 'group-local', wrap };
}
void glTakeWrap;

// Must fail: the same value arriving as a `JSON.parse`-shaped `unknown`
// — every runtime-shaped source, not just literals.
const glJsonDoc: unknown = JSON.parse('{"$form":"inner","$ns":"group-local","a":1,"b":2}');
// @ts-expect-error JSON.parse path — an unknown carrying both alternatives assigns to no arm
const glJson: GroupLocal_Canvas = { $form: 'canvas', $ns: 'group-local', wrap: glJsonDoc };

// Must fail: both alternatives of the local's group on one local value —
// the generic fallback must not absorb it.
const glBothDoc = {
  $form: 'canvas',
  $ns: 'group-local',
  wrap: { $form: 'inner', a: 1, b: 2 },
} as const;
// @ts-expect-error two complete alternatives — exactly-one [a, b] on the local `inner`
const glBoth: GroupLocal_Canvas = glBothDoc;

// Must fail: neither alternative — no arm of the local, no global by
// that name, and no `$ns` to reach a qualified arm.
const glNeitherDoc = {
  $form: 'canvas',
  $ns: 'group-local',
  wrap: { $form: 'inner', tag: 't' },
} as const;
// @ts-expect-error neither present — exactly-one [a, b] on the local `inner`
const glNeither: GroupLocal_Canvas = glNeitherDoc;

// Must fail: a qualified head naming a local-only name. A `$ns` head
// bypasses locals and resolves against the plugin catalog
// (Schema.lookupForm), and no plugin declares a *global* `inner` — the
// runtime calls this `unknown_form`, so no qualified arm may answer.
const glQualifiedLocalNameDoc = { $form: 'inner' as const, $ns: 'group-local' };
const glQualifiedLocalName: GroupLocal_Canvas = {
  $form: 'canvas',
  $ns: 'group-local',
  // @ts-expect-error qualified local-only name — `group-local/inner` is unknown_form at runtime, no arm answers
  wrap: glQualifiedLocalNameDoc,
};

// Must fail: a qualified head naming a namespace the model does not
// know — `unknown_form` at runtime, so the enumeration must not admit
// it either.
const glQualifiedUnknownNsDoc = { $form: 'inner' as const, $ns: 'other-plugin' };
const glQualifiedUnknownNs: GroupLocal_Canvas = {
  $form: 'canvas',
  $ns: 'group-local',
  // @ts-expect-error unknown namespace — `$ns` must name a plugin in the model (runtime: unknown_form)
  wrap: glQualifiedUnknownNsDoc,
};

// ── local-first shadowing — LocalForms_Canvas.shape ────────────────────────
// The local `circle` (r) shadows the global `circle` (radius): a bare
// head resolves against the local, so the global's shape is reachable
// only through a qualified value.

// Must compile: the local circle and the local-only rect.
const lfCircle: LocalForms_Canvas = {
  $form: 'canvas',
  $ns: 'local-forms',
  shape: { $form: 'circle', r: 12 },
} as const;
const lfRect: LocalForms_Canvas = {
  $form: 'canvas',
  $ns: 'local-forms',
  shape: { $form: 'rect', w: 2, h: 3 },
} as const;

// Must compile: the unqualified global `line` — built as a variable
// because the enumeration arm carries the head only (global keys are
// SJON-runtime-enforced; the literal would trip excess-property
// checking against the head-only arm).
const lfLineDoc = {
  $form: 'canvas',
  $ns: 'local-forms',
  shape: { $form: 'line', from: [0, 0], to: [1, 1] },
} as const;
const lfLine: LocalForms_Canvas = lfLineDoc;

// Must compile: the shadowed global circle, reached qualified. Variable
// form for the same reason — the qualified arm checks the head shape,
// not the global's keys.
const lfShadowedGlobalDoc = {
  $form: 'canvas',
  $ns: 'local-forms',
  shape: { $form: 'circle', $ns: 'local-forms', radius: 5 },
} as const;
const lfShadowedGlobal: LocalForms_Canvas = lfShadowedGlobalDoc;

// Must fail: the shadowed global's shape on a bare head — the runtime
// resolves `circle` against the local (which demands `r`), so the
// enumeration excludes the name and only the qualified arm could answer.
const lfBareGlobalShapeDoc = {
  $form: 'canvas',
  $ns: 'local-forms',
  shape: { $form: 'circle', radius: 5 },
} as const;
// @ts-expect-error shadowed head — bare `circle` resolves against the local (r), not the global (radius)
const lfBareGlobalShape: LocalForms_Canvas = lfBareGlobalShapeDoc;

// ── a unit-bearing grouped key — GroupUnits_Span ───────────────────────────
// The `width` arm's value is the unit tuple `readonly [number, "mm" | "cm"
// | "m"]`; the `@sjon-unit` JSDoc rides inside the multi-line arm.

// Must compile: each complete alternative alone (a unit tuple value, and
// the plain number), built as variables so the tuple literal's mutable
// array type is checked by assignability rather than fresh-literal
// inference.
const guWidthDoc = {
  $form: 'span',
  $ns: 'group-units',
  label: 'w',
  width: [120, 'cm'],
} as const;
const guWidth: GroupUnits_Span = guWidthDoc;
const guLegacy: GroupUnits_Span = {
  $form: 'span',
  $ns: 'group-units',
  legacy: 3,
} as const;

// Must fail: a unit outside the allowed set.
const guBadUnitDoc = {
  $form: 'span',
  $ns: 'group-units',
  width: [120, 'inch'],
} as const;
// @ts-expect-error unit not allowed — width accepts mm | cm | m only
const guBadUnit: GroupUnits_Span = guBadUnitDoc;

// Must fail: two complete alternatives (width and legacy).
const guBothDoc = {
  $form: 'span',
  $ns: 'group-units',
  width: [120, 'cm'],
  legacy: 3,
} as const;
// @ts-expect-error two complete alternatives — exactly-one [width, legacy]
const guBoth: GroupUnits_Span = guBothDoc;

// ── enforced beside defaulted — GroupMixed_Mixed ───────────────────────────
// exactly-one [a, b] stays enforced while the defaulted at-most-one
// [c, d] group is skipped whole: c/d stay optional in the base. The
// enforced sibling keeps its compile negative even if the goldens are
// regenerated around a regression (branch review §5).

// Must compile: either enforced arm alone, and either arm beside the
// defaulted group's keys.
const mixedA: GroupMixed_Mixed = {
  $form: 'mixed',
  $ns: 'group-mixed',
  a: 'x',
} as const;
const mixedBCD: GroupMixed_Mixed = {
  $form: 'mixed',
  $ns: 'group-mixed',
  b: 'y',
  c: 1,
  d: 2,
} as const;

// Must fail: two complete alternatives of the enforced group.
const mixedBothDoc = { $form: 'mixed', $ns: 'group-mixed', a: 'x', b: 'y' } as const;
// @ts-expect-error two complete alternatives — exactly-one [a, b] enforced beside the defaulted [c, d]
const mixedBoth: GroupMixed_Mixed = mixedBothDoc;

// Must fail: neither alternative of the enforced group (the defaulted
// sibling must not open a door).
const mixedNeitherDoc = { $form: 'mixed', $ns: 'group-mixed', c: 1 } as const;
// @ts-expect-error neither present — exactly-one [a, b] enforced beside the defaulted [c, d]
const mixedNeither: GroupMixed_Mixed = mixedNeitherDoc;

// ── at-most-one over required keys — GroupRequired_Either ─────────────────
// c and d are `:optional false`, yet the none-arm may omit both: the
// validator suppresses per-key required diagnostics for grouped keys,
// and only an active arm requires its key.

// Must compile: the none-arm (both grouped keys omitted), and each
// alternative alone.
const eitherNone: GroupRequired_Either = {
  $form: 'either',
  $ns: 'group-required',
  tag: 't',
} as const;
const eitherC: GroupRequired_Either = {
  $form: 'either',
  $ns: 'group-required',
  tag: 't',
  c: 1,
} as const;
const eitherD: GroupRequired_Either = {
  $form: 'either',
  $ns: 'group-required',
  tag: 't',
  d: 2,
} as const;

// Must fail: two complete alternatives.
const eitherBothDoc = {
  $form: 'either',
  $ns: 'group-required',
  tag: 't',
  c: 1,
  d: 2,
} as const;
// @ts-expect-error two complete alternatives — at-most-one [c, d] over required keys
const eitherBoth: GroupRequired_Either = eitherBothDoc;

// ── an open form's group is annotation-only — GroupOpen_Page ──────────────
// The runtime bypasses the group sweep for open forms, so both-present
// and neither-present must both compile: the type adds no closed-group
// restriction (ruling, skipped-open).

const openBoth: GroupOpen_Page = {
  $form: 'page',
  $ns: 'group-open',
  title: 't',
  a: 'x',
  b: 'y',
} as const;
const openNeither: GroupOpen_Page = {
  $form: 'page',
  $ns: 'group-open',
  title: 't',
} as const;

// ── open and defaulted locals stay annotation-only — GroupLocal_Board/Shelf ──
// `board`'s local `hint` is open and `shelf`'s local `tune` carries a
// defaulted alternative key, so neither group emits arms: both and
// neither inside those locals must compile, exactly as at form level.

const boardBoth: GroupLocal_Board = {
  $form: 'board',
  $ns: 'group-local',
  pick: { $form: 'hint', a: 1, b: 2 },
} as const;
const boardNeither: GroupLocal_Board = {
  $form: 'board',
  $ns: 'group-local',
  pick: { $form: 'hint' },
} as const;
const shelfBoth: GroupLocal_Shelf = {
  $form: 'shelf',
  $ns: 'group-local',
  pick: { $form: 'tune', a: 1, b: 2 },
} as const;
const shelfNeither: GroupLocal_Shelf = {
  $form: 'shelf',
  $ns: 'group-local',
  pick: { $form: 'tune' },
} as const;

// ── the not-all plugin — barrel and helper must not collide ───────────────
// The barrel for a plugin literally named `not-all` is `SjonNotAll`; the
// structural helper is `_SjonNotAll`. Both must be usable in one file.

const notAllBarrel: SjonNotAll = {
  $form: 'flag',
  $ns: 'not-all',
  name: { $sym: 'x' },
  on: true,
} as const;
void notAllBarrel;

// ── the downstream wgslayer frame shapes — GroupFrame_Frame ────────────────
// exactly-one [frame | size + matrix]; `rotation`/`pivot`/`scale`
// `:requires [frame]` and stay in the base.

// Must compile: `frame` alone, with its requires-gated TRS keys and clip.
const frameAlone: GroupFrame_Frame = {
  $form: 'frame',
  $ns: 'group-frame',
  id: { $sym: 'board' },
  frame: [0, 0, 512, 512],
  rotation: 12,
  pivot: [0.5, 0.5],
  scale: [1, 1],
  clip: true,
} as const;

// Must compile: `size` + `matrix` together.
const frameSizeMatrix: GroupFrame_Frame = {
  $form: 'frame',
  $ns: 'group-frame',
  id: { $sym: 'plate' },
  size: [200, 120],
  matrix: [1, 0, 0, 1, 0, 0],
} as const;

// Must compile: `frame` beside a partial competitor (`size` without `matrix`).
// Variable form — see the note on `threeABesidePartial`.
const frameBesidePartialDoc = {
  $form: 'frame',
  $ns: 'group-frame',
  id: { $sym: 'badge' },
  frame: [8, 8, 48, 24],
  size: [48, 24],
} as const;
const frameBesidePartial: GroupFrame_Frame = frameBesidePartialDoc;

// Must fail: both placement alternatives on one node — the U4
// consumer's `placement-both` document.
const framePlacementBothDoc = {
  $form: 'frame',
  $ns: 'group-frame',
  id: { $sym: 'plate' },
  frame: [8, 8, 48, 24],
  size: [48, 24],
  matrix: [1, 0, 0, 1, 8, 8],
} as const;
// @ts-expect-error two complete alternatives — exactly-one [frame, size + matrix]
const framePlacementBoth: GroupFrame_Frame = framePlacementBothDoc;

// Must fail: neither placement alternative — `placement-neither`.
const framePlacementNeitherDoc = {
  $form: 'frame',
  $ns: 'group-frame',
  id: { $sym: 'ghost' },
  clip: true,
} as const;
// @ts-expect-error neither present — exactly-one [frame, size + matrix]
const framePlacementNeither: GroupFrame_Frame = framePlacementNeitherDoc;

// Must fail: a lone partial bundle (`matrix` without `size`).
const frameLoneMatrixDoc = {
  $form: 'frame',
  $ns: 'group-frame',
  id: { $sym: 'skew' },
  matrix: [1, 0, 0, 1, 8, 8],
} as const;
// @ts-expect-error lone partial bundle — matrix without size is no alternative
const frameLoneMatrix: GroupFrame_Frame = frameLoneMatrixDoc;

void threeA;
void threeBC;
void threeC;
void threeABesidePartial;
void threeTwoComplete;
void threeNeither;
void threeLonePartial;
void threeFlattened;
void tagNone;
void tagFlank;
void tagLiteral;
void tagLiteralBesidePartial;
void tagLonePartial;
void tagBothComplete;
void routeEndpoints;
void routeAt;
void routeAtBesidePartial;
void routeLoneFrom;
void routeAllThree;
void xkeyBarrel;
void xkeyBarrelTag;
void reqA;
void reqB;
void reqBoth;
void pairA;
void pairB;
void pairAC;
void pairAD;
void pairBC;
void pairBD;
void pairBothFirst;
void pairBothSecond;
void frameAlone;
void frameSizeMatrix;
void frameBesidePartial;
void framePlacementBoth;
void framePlacementNeither;
void frameLoneMatrix;
void vpStepNone;
void vpSweepNone;
void vpStepGate;
void vpStepPass;
void vpSweepNoneArm;
void vpBass;
void vpNeitherFirst;
void vpBothFirst;
void vpBothSecond;
void glA;
void glB;
void glVarSingle;
void glGlobal;
void glVarBareGlobal;
void glVarQualified;
void canvas;
void glVarNeither;
void glJson;
void glBoth;
void glNeither;
void glQualifiedLocalName;
void glQualifiedUnknownNs;
void lfCircle;
void lfRect;
void lfLine;
void lfShadowedGlobal;
void lfBareGlobalShape;
void guWidth;
void guLegacy;
void guBadUnit;
void guBoth;
void mixedA;
void mixedBCD;
void mixedBoth;
void mixedNeither;
void eitherNone;
void eitherC;
void eitherD;
void eitherBoth;
void openBoth;
void openNeither;
void boardBoth;
void boardNeither;
void shelfBoth;
void shelfNeither;
