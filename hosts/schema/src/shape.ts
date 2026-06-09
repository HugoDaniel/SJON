// Builder IR — the pre-lowering value/form/plugin shapes the fluent
// builder accumulates at runtime. Drives serialization (`serialize.ts`)
// into the canonical `(plugin …)` manifest text that every SJON host
// consumes.
//
// This IR intentionally mirrors a *subset* of the exporter's
// post-lowering `ModelValueShape`
// (`hosts/typescript-parity/src/schemaExport/model.ts`) — the subset that
// round-trips through a hand-authorable manifest and validates identically
// on every host. It is deliberately NOT imported from there: the exporter
// IR is post-resolution (named refs flattened, refinement axes
// classified); this one is what the author typed. The conformance test
// (`infer<T>` ≡ `exportSchema(manifest()).tsTypes`) is the bridge that
// keeps the two in sync.
//
// Lifetime: pure immutable data, JS-owned. No allocator handle.

/** Inclusive/exclusive numeric refinement. Lowers to `(numeric-bounds …)`. */
export interface NumericBoundsIR {
  readonly min?: number;
  readonly max?: number;
  readonly exclusiveMin?: boolean;
  readonly exclusiveMax?: boolean;
  readonly integer?: boolean;
}

/** Length/pattern/format refinement. Lowers to `(string-bounds …)`. */
export interface StringBoundsIR {
  readonly minLen?: number;
  readonly maxLen?: number;
  readonly pattern?: string;
  /** A `StringFormat` name the host recognises: email, uri, uuid, semver, path, … */
  readonly format?: string;
}

/**
 * A cross-reference to another form's instance, keyed by a name slot.
 * Lowers to `:underlying symbol :cross-ref (cross-ref …)`.
 */
export interface CrossRefIR {
  readonly target: string;
  readonly nameKey?: string;
  readonly acyclic?: boolean;
  readonly scope?: string;
}

/**
 * The value-shape vocabulary the builder can express. Each variant maps
 * onto a manifest `:type` (builtins) or a generated `(value-kind …)`
 * (refined/composite leaves — see `serialize.ts`'s hoisting rule).
 */
export type ShapeIR =
  | { readonly kind: 'any' }
  | { readonly kind: 'nil' }
  | { readonly kind: 'boolean' }
  | { readonly kind: 'number'; readonly bounds?: NumericBoundsIR }
  | { readonly kind: 'string'; readonly bounds?: StringBoundsIR }
  | { readonly kind: 'symbol' }
  | { readonly kind: 'symbol_members'; readonly members: readonly string[] }
  | { readonly kind: 'string_members'; readonly members: readonly string[] }
  | { readonly kind: 'vector'; readonly element: ShapeIR; readonly len?: number }
  | { readonly kind: 'expr' }
  | { readonly kind: 'form_any' }
  // A *typed* nested form (`s.formOf(Other)`): the value at this slot must be a
  // `(head …)` of the carried `FormDef`. Serializes to a `(value-kind :underlying
  // form :heads (head-set :names [head]))` plus a hoisted `(form …)` declaration
  // for the inner form (see `serialize.ts`). Distinct from `form_any`, which
  // accepts any form. The recursive `ShapeIR → FormDef → FormKeyDef → NodeDef →
  // ShapeIR` cycle is fine — TS resolves recursive type aliases lazily.
  //
  // The payload is a `FormDef`, or a **thunk** `() => FormDef` for a
  // self-referential (recursive) form whose def isn't built yet at the point of
  // reference (`s.formOf(() => Self)`). Always read it through `resolveFormDef`;
  // the serializer's head-dedup terminates the resulting declaration cycle and
  // construction bottoms out on finite data.
  | { readonly kind: 'form'; readonly form: FormDef | (() => FormDef) }
  | { readonly kind: 'cross_ref'; readonly crossRef: CrossRefIR };

/**
 * Runtime payload carried by every builder node. Phantom `_out`/`_in`
 * types (the inference half) live only in the type layer
 * (`infer.ts`); this is the value half the serializer reads.
 */
export interface NodeDef {
  readonly shape: ShapeIR;
  /** Set by `.optional()`; partitions the owning form's key as `?`. */
  readonly isOptional: boolean;
  /** `.describe(...)` text — emitted as `:description "…"` on a hoisted kind. */
  readonly description?: string;
  /**
   * Preferred value-kind name when this leaf hoists (`s.slug()` → "slug",
   * `s.kind("score", …)` → "score"). Absent ⇒ the serializer generates a
   * stable structural name.
   */
  readonly suggestedKind?: string;
  /** True for `s.kind(name, …)` — the name is authoritative, never generated. */
  readonly explicitKind?: boolean;
  /**
   * Set by `.default(v)` — the default value (a `SjonValue`: literal or `e.*`
   * expr). Emitted as `:default <literal>` into the manifest (`serialize.ts`),
   * making the key optional in input but required in output. Distinct from
   * `isOptional`. See docs/plans/02 workstream B.
   */
  readonly default?: unknown;
}

/** One declared key of a form: a name bound to a value node's def. */
export interface FormKeyDef {
  readonly name: string;
  readonly def: NodeDef;
}

/** Positional-child policy of a form. */
export type PositionalDef =
  | { readonly kind: 'none' }
  | { readonly kind: 'any' }
  | { readonly kind: 'typed'; readonly element: NodeDef };

/** A `(form …)` declaration. */
export interface FormDef {
  readonly head: string;
  /** Owning plugin name — becomes the data form's `$ns`. */
  readonly ns: string;
  readonly description?: string;
  readonly open: boolean;
  readonly positional: PositionalDef;
  readonly keys: readonly FormKeyDef[];
}

/**
 * Resolve a `kind: 'form'` shape's carried form, invoking the thunk for a lazy
 * (self-referential) form. The thunk returns an already-built `_def`, so this is
 * O(1) and idempotent — no memoization needed. Every reader of the nested-form
 * payload (serializer, constructor) goes through here.
 */
export function resolveFormDef(shape: Extract<ShapeIR, { kind: 'form' }>): FormDef {
  return typeof shape.form === 'function' ? shape.form() : shape.form;
}

/** An explicitly-named `(value-kind …)` declaration (`s.kind`). */
export interface NamedKindDef {
  readonly name: string;
  readonly def: NodeDef;
}

/** A `(plugin …)` declaration grouping forms + named kinds. */
export interface PluginDef {
  readonly name: string;
  readonly version: string;
  readonly description?: string;
  readonly forms: readonly FormDef[];
  readonly namedKinds: readonly NamedKindDef[];
}
