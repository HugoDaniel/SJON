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
}

export type ModelPositional =
  | { readonly kind: 'none' }
  | { readonly kind: 'any' }
  | { readonly kind: 'kind'; readonly shape: ModelValueShape };

export interface ModelDiscriminator {
  readonly keyName: string;
  readonly variants: readonly ModelVariant[];
}

export interface ModelVariant {
  readonly when: string;
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
  | { readonly kind: 'form_heads'; readonly heads: readonly ModelFormRef[] }
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
  readonly targetForm: string;
  readonly nameKey: string;
  readonly acyclic: boolean;
  readonly scopeForm: string | null;
  readonly provider: string | null;
  readonly sourceKey: string | null;
}

export interface ModelFormRef {
  /** Owning plugin name. Empty string when the lowering pass couldn't resolve. */
  readonly plugin: string;
  readonly name: string;
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
