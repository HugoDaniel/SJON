// Intermediate representation for the schema exporter — TypeScript port
// of `src/SchemaExport/Model.zig`.
//
// The IR is a 1:1 transformation of `Schema` into a shape that has
// already resolved every named reference and classified every
// refinement axis. Backends (`jsonSchema.ts`, `tsTypes.ts`) walk it
// mechanically; lossy-mapping decisions, name collision resolution,
// and warning emission live in `lower.ts`.
//
// Lifetime: pure data, immutable after lowering. No allocator handle
// needed — JS owns memory.

import type { Repr, StringFormat } from '../plugin.ts';

export interface Model {
  readonly plugins: readonly ModelPlugin[];
  readonly version: number; // stamp; bumped on any breaking format change
}

export interface ModelPlugin {
  readonly name: string;
  readonly version: string;
  readonly description: string;
  readonly forms: readonly ModelForm[];
  readonly valueKinds: readonly ModelValueKindEntry[];
}

export interface ModelForm {
  readonly name: string;
  readonly description: string;
  readonly keys: readonly ModelKey[];
  readonly positional: ModelPositional;
  readonly open: boolean;
  /**
   * Discriminator + variants snapshot. `null` for non-discriminated
   * forms. M2 constructs the TS-parity manifest loader doesn't yet
   * parse stay `null`; the lowering pass surfaces a warning when this
   * happens against a manifest known to carry one.
   */
  readonly discriminator: ModelDiscriminator | null;
  readonly exclusiveGroups: readonly ModelExclusiveGroup[];
  readonly lowering: ModelLowering | null;
  /**
   * Positional keyword flags from a `(flag-set …)` slot, or `undefined`
   * when the form's positional is not a flag-set. The `positional` field
   * widens to `any` (flags don't constrain a child value shape); these
   * ride alongside as the `x-sjon-positional-flags` annotation.
   */
  readonly positionalFlags?: readonly ModelPositionalFlag[];
}

export interface ModelPositionalFlag {
  readonly name: string;
  readonly description?: string;
  readonly link?: string;
}

export interface ModelKey {
  readonly name: string;
  readonly optional: boolean;
  readonly description: string;
  readonly value: ModelValueShape;
  readonly default: ModelDefault | null;
  // Sibling keys this key's presence demands, from `KeySpec.requires`.
  // Exports as 2020-12 `dependentRequired` on the JSON Schema channel and
  // as a `@sjon-requires` JSDoc line on the TS one.
  readonly requires: readonly string[];
}

export type ModelPositional =
  | { readonly kind: 'none' }
  | { readonly kind: 'any' }
  | { readonly kind: 'kind'; readonly shape: ModelValueShape };

export interface ModelDiscriminator {
  readonly keyName: string;
  readonly variants: readonly ModelVariant[];
}

/** One variant gate. `when` lists the discriminant values that select it
 *  (`Variant.when`, never empty): a one-value variant emits exactly as it did
 *  when `:when` took one symbol (`const` / `Symbol_<"a">` / `"when": "a"`), a
 *  multi-value one guards the same single branch with an enum (`enum` /
 *  `Symbol_<"a" | "b">` / `"when": ["a", "b"]`) — the shape does not multiply
 *  the output. Mirrors `Model.Variant`. */
export interface ModelVariant {
  readonly when: readonly string[];
  readonly keys: readonly ModelKey[];
}

export type Cardinality = 'exactly_one' | 'at_most_one';

export interface ModelExclusiveGroup {
  readonly cardinality: Cardinality;
  /**
   * Each alternative is a bundle of key names that must appear together
   * (M3 multi-key bundles). Single-key alternatives are wrapped as
   * one-element bundles.
   */
  readonly alternatives: readonly (readonly string[])[];
}

export interface ModelLowering {
  readonly hook: string;
  readonly produces: readonly string[];
}

export type ModelValueShape =
  | { readonly kind: 'any' }
  | { readonly kind: 'nil' }
  | { readonly kind: 'boolean' }
  | { readonly kind: 'number' }
  | { readonly kind: 'number_i64' }
  | { readonly kind: 'number_u64' }
  | { readonly kind: 'number_bounded'; readonly bounds: ModelNumericBounds }
  | { readonly kind: 'number_with_unit'; readonly unit: ModelUnitShape }
  | { readonly kind: 'string' }
  | { readonly kind: 'string_with_bounds'; readonly bounds: ModelStringBounds }
  | { readonly kind: 'symbol' }
  | { readonly kind: 'symbol_members'; readonly members: readonly string[] }
  | { readonly kind: 'symbol_members_rich'; readonly members: readonly ModelMember[] }
  | { readonly kind: 'string_members'; readonly members: readonly string[] }
  | { readonly kind: 'string_members_rich'; readonly members: readonly ModelMember[] }
  | { readonly kind: 'date' }
  | { readonly kind: 'time' }
  | { readonly kind: 'keyword' }
  | { readonly kind: 'vector'; readonly vector: ModelVectorShape }
  | { readonly kind: 'form_any' }
  // A head-set slot. `heads` are the resolved members; `minChildren` /
  // `maxChildren` are the count over the *whole* set, which per-head
  // bounds structurally cannot express. Both levels are meaningful only
  // at a form's `:positional` slot. Mirrors `Model.HeadSetShape` in
  // `src/SchemaExport/Model.zig`.
  | {
      readonly kind: 'form_heads';
      readonly heads: readonly ModelFormRef[];
      readonly minChildren?: number;
      readonly maxChildren?: number;
    }
  // Slot-local forms (`KeySpec.localForms`): fully-lowered `ModelForm`s the
  // slot resolves local-first, then falls back additively to the global
  // catalog. Backends emit an inline anonymous union — one object schema per
  // local plus a trailing open generic branch for the additive fallback.
  // Mirrors `Model.ValueShape.form_locals` in `src/SchemaExport/Model.zig`.
  | { readonly kind: 'form_locals'; readonly forms: readonly ModelForm[] }
  | { readonly kind: 'expr' }
  | { readonly kind: 'cross_ref'; readonly crossRef: ModelCrossRef }
  | { readonly kind: 'union_of'; readonly alternatives: readonly ModelUnionAlternative[] }
  | { readonly kind: 'unresolved_named'; readonly name: string; readonly namespace: string | null };

export interface ModelVectorShape {
  readonly len: number | null;
  /** Inclusive element-count floor (`:min-len`) → `minItems`. */
  readonly minLen: number | null;
  /** Inclusive element-count ceiling (`:max-len`) → `maxItems`. */
  readonly maxLen: number | null;
  readonly element: ModelValueShape;
}

export interface ModelUnitShape {
  readonly required: boolean;
  readonly allowed: readonly string[];
  readonly bounds: ModelNumericBounds | null;
}

export interface ModelStringBounds {
  readonly minLen: number | null;
  readonly maxLen: number | null;
  readonly pattern: string | null;
  readonly format: StringFormat | null;
}

export interface ModelNumericBound {
  readonly value: number;
  readonly unit: string | null;
  readonly exactInt: boolean;
  /**
   * Raw decimal digits when the bound was lexed as an exact integer
   * literal exceeding 2^53. Backends recover full precision via the
   * `x-sjon-exact-bound` annotation. `null` when the bound fits in f64
   * losslessly.
   */
  readonly exactIntDigits: string | null;
}

export interface ModelNumericBounds {
  readonly min: ModelNumericBound | null;
  readonly max: ModelNumericBound | null;
  readonly exclusiveMin: boolean;
  readonly exclusiveMax: boolean;
  readonly integer: boolean;
  // Divisor from `:multiple-of` (manifest format 1.3). Exports exactly on
  // the JSON Schema channel — 2020-12's `multipleOf` is "division by this
  // keyword's value results in an integer", the same claim SJON makes —
  // and is JSDoc-annotation-only on the TS channel, which has no
  // divisibility constraint. `null` when the source declared none.
  readonly multipleOf: ModelNumericBound | null;
  // GPU representation tag from `:repr (repr-shape …)`. Drives the
  // `x-sjon-gpu-repr` JSON Schema annotation and a branded `F32`…`F16` TS
  // alias. `null` when the source declared no `:repr`. Orthogonal to
  // min/max/integer — a repr-only kind sets just this.
  readonly repr: Repr | null;
}

export interface ModelMember {
  readonly name: string;
  readonly label: string;
  readonly description: string;
  readonly deprecated: boolean;
  readonly deprecationMessage: string;
  /** Set when the spelling is digit-leading (`1d`, `2d`), in which case a
   *  document writes it as a unit-bearing number and the JSON bridge
   *  encodes it as `{"$num": [magnitude, unit]}`. A schema pinning
   *  `{"$sym": "2d"}` would reject a document the validator accepts, so
   *  every backend has to know. Mirrors `Model.Member.numeric_spelling`. */
  readonly numericSpelling?: ModelNumericSpelling;
}

export interface ModelNumericSpelling {
  readonly magnitude: number;
  readonly unit: string;
}

/**
 * Mirror of `Model.CrossRef` in `src/SchemaExport/Model.zig`. `provider`
 * and `sourceKey` are the provider route: both null on the identity route,
 * both non-null on the provider one (a source key without a provider is
 * rejected at manifest load). Nothing here is enforceable by any export
 * target, and the provider route is the less enforceable of the two — its
 * member set does not exist until a host runs an extraction pre-pass over
 * a document the exporter never sees.
 */
export interface ModelCrossRef {
  /** Every listed target, in manifest order; never empty. A group's
   * members share one namespace in the engine, which no export target can
   * express — but the IR carries the whole list rather than a
   * first-target summary an IR reader could mistake for the truth. */
  readonly targets: readonly string[];
  readonly nameKey: string;
  readonly acyclic: boolean;
  readonly scopeForm: string | null;
  readonly provider: string | null;
  readonly sourceKey: string | null;
}

/**
 * What a head-set member resolves to, at the slot the head-set was
 * lowered for — the order `Validator.validateFormHead` step 0 tries.
 * Mirrors `Model.FormRef.Body` in `src/SchemaExport/Model.zig`.
 *
 * A head-set kind is plugin-wide and reusable, so which of these applies
 * is a property of the *slot*, not of the kind: the same kind can be
 * `local` on a slot that declares the body inline and `unresolved` on
 * one that does not.
 */
export type ModelFormRefBody =
  /** A unique global form — `$ref` into `#/$defs/form.<plugin>.<name>`. */
  | { readonly kind: 'global' }
  /**
   * A slot-local form. Locals have no global `$def`, so the body is
   * emitted in place, the same way `form_locals` emits its arms.
   */
  | { readonly kind: 'local'; readonly form: ModelForm }
  /**
   * Nothing in scope resolves this head. Backends emit a head-pinned
   * open object and **never** a `$ref`: an unresolvable `$ref` makes a
   * 2020-12 validator reject the whole document at compile time.
   */
  | { readonly kind: 'unresolved' };

export interface ModelFormRef {
  /**
   * Owning plugin. Meaningful for `global` (it selects the `$defs`
   * table) and for `local` (the plugin the enclosing form belongs to);
   * empty only for `unresolved`.
   */
  readonly plugin: string;
  readonly name: string;
  /**
   * Positional-count bounds carried over from the source `Head`.
   * Meaningful only where this ref reached the model through a form's
   * `:positional` slot (the scope rule in
   * `docs/portable-manifest-v1.md` §4.5), so the backends read them only
   * when emitting `$children`. Absent = unbounded, and an all-unbounded
   * head-set therefore exports byte-identically to before bounds
   * existed. Mirrors `Model.FormRef` in `src/SchemaExport/Model.zig`.
   */
  readonly min?: number;
  readonly max?: number;
  /**
   * Absent means `global` — the shape every head-set carried before
   * slot-aware resolution, so a global-only head-set is unchanged.
   */
  readonly body?: ModelFormRefBody;
}

/** The resolution route of a ref, defaulting an absent `body` to global. */
export function refBody(ref: ModelFormRef): ModelFormRefBody {
  return ref.body ?? { kind: 'global' };
}

/** True when a ref declares a count worth emitting. */
export function isBoundedRef(ref: ModelFormRef): boolean {
  return (ref.min ?? 0) !== 0 || ref.max !== undefined;
}

/** One head-set shape, narrowed out of `ModelValueShape`. */
export type ModelHeadSetShape = Extract<ModelValueShape, { kind: 'form_heads' }>;

/** True when the *set* declares a count. `isBoundedRef`'s counterpart,
 *  one level up. Mirrors `Model.HeadSetShape.isBounded`. */
export function isBoundedSet(hs: ModelHeadSetShape): boolean {
  return (hs.minChildren ?? 0) !== 0 || hs.maxChildren !== undefined;
}

/** True when anything here declares a count — some head, or the set. The
 *  `$children` backends gate on this, so an all-unbounded head-set emits
 *  no bounds block at all. Mirrors `Model.HeadSetShape.anyBounded`. */
export function anyBoundedInSet(hs: ModelHeadSetShape): boolean {
  return isBoundedSet(hs) || hs.heads.some(isBoundedRef);
}

/** True when the slot demands at least one positional child — some
 *  head's `:min`, or the set's `:min-children`. Distinct from
 *  `anyBoundedInSet` because a ceiling-only slot is bounded and demands
 *  nothing, and the difference decides whether `$children` is `required`.
 *  Mirrors `Model.HeadSetShape.hasFloor`. */
export function headSetHasFloor(hs: ModelHeadSetShape): boolean {
  return (hs.minChildren ?? 0) > 0 || hs.heads.some((h) => (h.min ?? 0) > 0);
}

export interface ModelUnionAlternative {
  readonly name: string;
  readonly shape: ModelValueShape;
}

export interface ModelValueKindEntry {
  readonly name: string;
  readonly description: string;
  readonly shape: ModelValueShape;
  /** Plugin that owns this kind. Empty for unresolved entries. */
  readonly originPlugin: string;
}

export interface PerPluginArtifact {
  readonly plugin: string;
  readonly jsonSchema: string | null;
  readonly tsTypes: string | null;
  readonly intermediate: string | null;
}

export type ModelDefault =
  | { readonly kind: 'nil' }
  | { readonly kind: 'boolean'; readonly value: boolean }
  | { readonly kind: 'number'; readonly value: number }
  | { readonly kind: 'string'; readonly value: string }
  | { readonly kind: 'symbol'; readonly value: string }
  | { readonly kind: 'vector'; readonly elements: readonly ModelDefault[] }
  | { readonly kind: 'expression'; readonly snapshot: ModelExpressionSnapshot };

export interface ModelExpressionSnapshot {
  readonly head: string;
  readonly namespace: string | null;
  readonly argCount: number;
}
