// Inference layer — the Zod trick: phantom `_out`/`_in` type fields the
// builder never assigns at runtime, plus the mapped types that turn a
// `FormNode`'s shape record into its static output type.
//
// The output table here is faithful to the `.d.ts` the schema exporter
// emits (`hosts/typescript-parity/src/schemaExport/tsTypes.ts`): a
// builder `s.form(...)` and `exportSchema(manifest).tsTypes` must agree,
// which is what the conformance test pins. The brand aliases below are a
// byte-for-byte copy of that emitter's `BRAND_PRELUDE` so the two are
// structurally identical (and therefore mutually assignable).

import type { EditAction, EditPath } from './edit.ts';
import type { FormDef, NodeDef, PluginDef } from './shape.ts';
import type {
  ParseOptions,
  SafeEditResult,
  SafeParseResult,
  ToDtsOptions,
  ValidateOutcome,
} from './backend.ts';

// --- Brands (copy of tsTypes.ts BRAND_PRELUDE) -----------------------------

export type Keyword<S extends string = string> = { readonly $kw: S };
export type Symbol_<S extends string = string> = { readonly $sym: S };
export type SjonDate = { readonly $date: string };
export type SjonTime = { readonly $time: string };
/** A unit-suffixed number (`{$num:[90,"deg"]}` → `90deg`). No plan-01 brand. */
export type SjonUnit<U extends string = string> = { readonly $num: readonly [number, U] };
export type SjonExpr<TResult = unknown> = { readonly $expr: unknown[] } & {
  readonly __sjonResult?: TResult;
};
export type CrossRef<TargetForm extends string = string, S extends string = string> = Symbol_<S> & {
  readonly __sjonRef?: TargetForm;
};

// --- Node interfaces -------------------------------------------------------

/**
 * A schema node. `_out`/`_in` are phantom — present in the type, never
 * assigned at runtime (the builder casts). `_def` is the real runtime
 * payload the serializer reads.
 */
export interface Node<Out, In = Out> {
  readonly _out: Out;
  readonly _in: In;
  readonly _def: NodeDef;
  /** Mark this node's owning form-key optional (`?`). */
  optional(): OptionalNode<Out, In>;
  /**
   * Give this node's owning form-key a default. The key becomes optional in the
   * *input* type (`s.input` / `Form.create`) but stays required in the *output*
   * type (`s.infer`) — `create` / the engine fills the default. The value is a
   * literal of the input type or an `e.*` expression evaluating to it.
   */
  default(value: In | SjonExpr<Out>): DefaultedNode<Out, In>;
  /** Attach a description (emitted as `:description` on a hoisted value-kind). */
  describe(description: string): this;
}

/** A node tagged optional. The `__optional` marker drives `FormOut`'s `?`. */
export type OptionalNode<Out, In = Out> = Node<Out, In> & { readonly __optional: true };

/**
 * A node tagged with a default. The `__default` marker makes the key optional
 * in the *input* partition only (`FormIn` / `FormInput`); `FormOut` ignores it,
 * so the output key stays required — matching the exporter, which emits a
 * defaulted-not-optional key as required + `@default`.
 */
export type DefaultedNode<Out, In = Out> = Node<Out, In> & { readonly __default: true };

export type AnyNode = Node<unknown, unknown>;
export type ShapeRecord = Record<string, AnyNode>;

/**
 * Distribute a member union into a union of single-member symbol brands —
 * `MemberSymbol<"a" | "b">` is `Symbol_<"a"> | Symbol_<"b">`, matching the
 * `Symbol_<"a"> | Symbol_<"b">` that `tsTypes.ts` emits (not the collapsed
 * `Symbol_<"a" | "b">`).
 */
export type MemberSymbol<E extends string> = E extends string ? Symbol_<E> : never;

/**
 * A *typed nested-form* field node (`s.formOf(Inner)`). It is structurally a
 * `Node<FormOut, FormIn>`, so every output/input mapping (`OutOf`/`InOf`/
 * `FormOut`/`FormIn`/`FormInput`/the key partitions) recurses through it with
 * no change, and `.optional()`/`.default()` come free from the `leaf` factory.
 * The `__formOf` phantom carries the inner `{ns,head,shape}` so the typed
 * path-resolver (plan 03 P2.3) can descend into it; never assigned at runtime.
 *
 * Deliberately a wrapper around `Node` rather than admitting a raw `FormNode`
 * into `ShapeRecord`: the latter is self-referential
 * (`FormNode._out → FormOut → ShapeRecord → FormNode`) and trips TS's
 * "excessively deep" guard.
 *
 * ## Recursive forms — two inherent TS-compiler limits
 *
 * `s.formOf(() => Self)` (see `formOf` in `builder.ts`) makes a form nest
 * itself. No Zig change is needed — the validator and serializer already accept
 * self-referential forms (the engine's own data-depth guard, `MAX_KIND_DEPTH`,
 * caps actual nesting, not the declaration). But two consequences of TS's type
 * system, not removable here, apply:
 *
 *  1. **Explicit annotation required.** A recursive form's inferred output type
 *     is value-circular (`const Tree = s.form(… s.formOf(() => Tree) …)` reads
 *     `Tree` before it's typed), so `tsc` reports "implicitly has type 'any'
 *     because it references itself". Annotate the binding —
 *     `const Tree: FormNode<'tree', 'tree', { … }> = s.form(…)` — to break it.
 *  2. **Typed deep paths cap at the `Depth` budget.** The path-resolver's
 *     recursion is bounded (`Depth` = 6, below) so `tsc` never hits "excessively
 *     deep". Edit paths that descend past that into the recursive region fall
 *     back to the untyped low-level `edit.*` builders; runtime edits are
 *     unaffected. This mirrors the engine's own `MAX_KIND_DEPTH = 8` data cap.
 */
export interface FormFieldNode<NS extends string, Head extends string, Sh extends ShapeRecord>
  extends Node<FormOut<NS, Head, Sh>, FormIn<NS, Head, Sh>> {
  // Required (not `?`) so the path-resolver can discriminate it reliably — an
  // optional marker is satisfied by absence and matches every node. Phantom:
  // never assigned at runtime (the `leaf` factory casts), like `_out`/`_in`.
  readonly __formOf: { readonly ns: NS; readonly head: Head; readonly shape: Sh };
}

/**
 * A vector node that remembers its element node `E` in a type-only `__element`
 * phantom, so the typed path-resolver can descend `s.vector(s.formOf(Inner))`
 * into the element form. Structurally `Node<Out,Out>` — assignable anywhere a
 * plain vector `Node` was, and a no-op for primitive-element vectors.
 */
export type VectorNode<E extends AnyNode, Out> = Node<Out, Out> & {
  // Required for the same reason as `FormFieldNode.__formOf` — reliable
  // discrimination/inference by the path-resolver. Phantom, never assigned.
  readonly __element: E;
};

/** `s.number()` — a `number` leaf with numeric refinements. */
export interface NumberNode extends Node<number> {
  min(value: number): NumberNode;
  max(value: number): NumberNode;
  gt(value: number): NumberNode;
  lt(value: number): NumberNode;
  int(): NumberNode;
}

/** `s.string()` — a `string` leaf with length/pattern/format refinements. */
export interface StringNode extends Node<string> {
  minLen(value: number): StringNode;
  maxLen(value: number): StringNode;
  pattern(regex: string): StringNode;
  format(name: string): StringNode;
}

// --- Leaf → output mapping helpers -----------------------------------------

type Prettify<T> = { [K in keyof T]: T[K] } & {};

export type OutOf<N> = N extends Node<infer O, infer _I> ? O : never;
export type InOf<N> = N extends Node<infer _O, infer I> ? I : never;

// Output partition: a key is optional iff `.optional()` (the `__optional`
// marker). A defaulted-but-not-optional key stays REQUIRED in the output.
type IsOptional<N> = N extends { readonly __optional: true } ? true : false;

type RequiredShapeKeys<Sh extends ShapeRecord> = {
  [K in keyof Sh]: IsOptional<Sh[K]> extends true ? never : K;
}[keyof Sh];

type OptionalShapeKeys<Sh extends ShapeRecord> = {
  [K in keyof Sh]: IsOptional<Sh[K]> extends true ? K : never;
}[keyof Sh];

// Input partition: a key is optional iff `.optional()` OR `.default()` — a
// defaulted key may be omitted from the input (`create` / the engine fills it).
type IsInputOptional<N> = N extends { readonly __optional: true }
  ? true
  : N extends { readonly __default: true }
    ? true
    : false;

type RequiredInputKeys<Sh extends ShapeRecord> = {
  [K in keyof Sh]: IsInputOptional<Sh[K]> extends true ? never : K;
}[keyof Sh];

export type OptionalInputKeys<Sh extends ShapeRecord> = {
  [K in keyof Sh]: IsInputOptional<Sh[K]> extends true ? K : never;
}[keyof Sh];

/**
 * A form's static output type — the Zod optional-key partition over the
 * shape record, plus the literal `$form`/`$ns` tags. Structurally equal
 * to the `<Plugin>_<Form>` interface `tsTypes.ts` emits.
 */
export type FormOut<NS extends string, Head extends string, Sh extends ShapeRecord> = Prettify<
  { readonly $form: Head; readonly $ns: NS } & {
    readonly [K in RequiredShapeKeys<Sh>]: OutOf<Sh[K]>;
  } & {
    readonly [K in OptionalShapeKeys<Sh>]?: OutOf<Sh[K]>;
  }
>;

/**
 * A form's static input type. Uses the *input* partition, so a defaulted key
 * is optional here (it may be omitted) even though it is required in `FormOut`.
 */
export type FormIn<NS extends string, Head extends string, Sh extends ShapeRecord> = Prettify<
  { readonly $form: Head; readonly $ns: NS } & {
    readonly [K in RequiredInputKeys<Sh>]: InOf<Sh[K]>;
  } & {
    readonly [K in OptionalInputKeys<Sh>]?: InOf<Sh[K]>;
  }
>;

/**
 * Constructor input for `Form.create` — the form's fields only. The `$form` /
 * `$ns` tags are stamped by `create` from the schema, so unlike `FormIn` they
 * are not part of the input. Uses the input partition (defaulted ⇒ optional).
 */
export type FormInput<Sh extends ShapeRecord> = Prettify<
  {
    readonly [K in RequiredInputKeys<Sh>]: InOf<Sh[K]>;
  } & {
    readonly [K in OptionalInputKeys<Sh>]?: InOf<Sh[K]>;
  }
>;

/**
 * A fixed-length readonly tuple of `E`, for `s.vector(el, n)`. Mirrors
 * `tsTypes.ts`: lengths 1–8 become tuples, anything larger (or unknown)
 * falls back to `Array<E>`.
 */
export type FixedTuple<E, N extends number> = N extends 1
  ? readonly [E]
  : N extends 2
    ? readonly [E, E]
    : N extends 3
      ? readonly [E, E, E]
      : N extends 4
        ? readonly [E, E, E, E]
        : N extends 5
          ? readonly [E, E, E, E, E]
          : N extends 6
            ? readonly [E, E, E, E, E, E]
            : N extends 7
              ? readonly [E, E, E, E, E, E, E]
              : N extends 8
                ? readonly [E, E, E, E, E, E, E, E]
                : readonly E[];

// --- Form / plugin nodes ---------------------------------------------------

/**
 * A `(form …)` schema. Carries the phantom output type and the runtime
 * methods that serialize + validate through the registered backend.
 */
export interface FormNode<NS extends string, Head extends string, Sh extends ShapeRecord> {
  readonly _out: FormOut<NS, Head, Sh>;
  readonly _in: FormIn<NS, Head, Sh>;
  readonly _def: FormDef;
  describe(description: string): FormNode<NS, Head, Sh>;
  /**
   * Construct a conformant form value from typed fields: stamps `$form`/`$ns`
   * from the schema, fills declared defaults for omitted defaulted keys, and
   * omits absent optionals. Returns the plain typed `FormOut` (not a wrapper),
   * so a constructed form composes as a field/child of another value.
   * Backend-free.
   */
  create(input: FormInput<Sh>): FormOut<NS, Head, Sh>;
  /** Construct + serialize to canonical SJON text via `serializeValue`. Backend-free. */
  toSjon(input: FormInput<Sh>): string;
  /**
   * Construct + serialize via the engine's own canonical printer
   * (`backend.fromValue`). Equivalent to `toSjon` modulo formatting, but
   * WASM-gated — use `toSjon` for a backend-free path.
   */
  toCanonicalSjon(input: FormInput<Sh>, options?: ParseOptions): string;
  /** The canonical `(plugin …)` manifest text for this form. */
  manifest(): string;
  /** The exporter's `.d.ts` for this form's schema (needs an `exportSchema` backend). */
  toDts(options?: ToDtsOptions): string;
  /**
   * Validate a SJON document against this form's schema and return the raw
   * diagnostic stream. Unlike `parse`, this needs only `validate` — it works
   * on any backend (including validation-only ones like the native TS host).
   */
  validate(source: string, options?: ParseOptions): ValidateOutcome;
  /** Validate a SJON document and return the typed data (throws on `err`). */
  parse(source: string, options?: ParseOptions): FormOut<NS, Head, Sh>;
  safeParse(source: string, options?: ParseOptions): SafeParseResult<FormOut<NS, Head, Sh>>;
  /** Validate a JS value (round-tripped through SJON) and return it typed. */
  parseValue(value: FormIn<NS, Head, Sh>, options?: ParseOptions): FormOut<NS, Head, Sh>;
  safeParseValue(
    value: FormIn<NS, Head, Sh>,
    options?: ParseOptions,
  ): SafeParseResult<FormOut<NS, Head, Sh>>;

  // --- Edit / write-back (plan 03) -----------------------------------------
  // All WASM-gated: the engine is a Zig printer (`.full`, trivia-preserving),
  // so these throw `SjonEditError` / a clear gate error on a non-edit backend.

  /** Apply one low-level structural {@link EditAction}; returns the re-printed text. */
  applyEdit(source: string, action: EditAction, options?: ParseOptions): string;
  /**
   * Set a key, deep-typed: `setKey(src, ['items', 0, 'done'], true)`. The value
   * is checked against the key the path resolves to.
   */
  setKey<P extends SetKeyPath<Sh>>(
    source: string,
    path: P,
    value: SetKeyValue<Sh, P>,
    options?: ParseOptions,
  ): string;
  /** Set a top-level key: `setKey(src, 'title', 'hi')`. */
  setKey<K extends keyof Sh & string>(
    source: string,
    key: K,
    value: InOf<Sh[K]>,
    options?: ParseOptions,
  ): string;
  /** Remove a key, deep-typed — terminal gated to optional/defaulted keys. */
  removeKey<P extends RemoveKeyPath<Sh>>(source: string, path: P, options?: ParseOptions): string;
  /** Remove a top-level optional/defaulted key. */
  removeKey<K extends OptionalInputKeys<Sh> & string>(
    source: string,
    key: K,
    options?: ParseOptions,
  ): string;
  /** Replace the value at a path (a key, a vector element, or deeper). */
  replaceAt<P extends ReplacePath<Sh>>(
    source: string,
    path: P,
    value: ReplaceValue<Sh, P>,
    options?: ParseOptions,
  ): string;
  /**
   * Diff `partial` against the current document and apply the minimal set of
   * top-level key updates (`undefined` ⇒ leave alone). Trivia outside the
   * changed keys survives. Needs `toJson` (to read the source) + `applyEdit`.
   */
  patch(source: string, partial: Partial<FormInput<Sh>>, options?: ParseOptions): string;
  /** `applyEdit`, returning a {@link SafeEditResult} instead of throwing. */
  safeApplyEdit(source: string, action: EditAction, options?: ParseOptions): SafeEditResult;
  /** `patch`, returning a {@link SafeEditResult} instead of throwing. */
  safePatch(
    source: string,
    partial: Partial<FormInput<Sh>>,
    options?: ParseOptions,
  ): SafeEditResult;
  /**
   * Open `source` as a stateful, chainable edit handle (the `open → set → save`
   * model). Queues edits and folds them over the *original* source on `save()`,
   * so trivia survives. Needs `toJson` (initial value) + `applyEdit`.
   */
  open(source: string, options?: ParseOptions): FormDocument<NS, Head, Sh>;
}

/**
 * A stateful edit handle over one opened document (`Form.open(source)`). Queues
 * typed `set`/`remove`/`edit` actions; `value` previews the result (eager for
 * top-level edits, lazily re-derived after a deep/positional `edit`); `save`
 * folds the queue over the **original** source, so comments/formatting outside
 * the edited subtrees are preserved.
 */
export interface FormDocument<NS extends string, Head extends string, Sh extends ShapeRecord> {
  /** Current value — eager for top-level edits, re-derived via the engine after a deep edit. */
  readonly value: FormOut<NS, Head, Sh>;
  /** The queued edits, in order. */
  readonly actions: readonly EditAction[];
  /** Set a key, deep-typed. Chainable. */
  set<P extends SetKeyPath<Sh>>(path: P, value: SetKeyValue<Sh, P>): this;
  /** Set a top-level key. Chainable. */
  set<K extends keyof Sh & string>(key: K, value: InOf<Sh[K]>): this;
  /** Remove an optional/defaulted key, deep-typed. Chainable. */
  remove<P extends RemoveKeyPath<Sh>>(path: P): this;
  /** Remove a top-level optional/defaulted key. Chainable. */
  remove<K extends OptionalInputKeys<Sh> & string>(key: K): this;
  /** Queue a low-level structural edit (deep/positional escape hatch). Chainable. */
  edit(action: EditAction): this;
  /** Fold the queued edits over the original source → trivia-preserving text; optionally validate. */
  save(options?: { readonly validate?: boolean }): string;
  /** `save` (no validate) returning a {@link SafeEditResult} instead of throwing. */
  safeSave(): SafeEditResult;
  /** Equivalent to `save()`. */
  toString(): string;
}

export type AnyFormNode = FormNode<string, string, ShapeRecord>;

/** A `(plugin …)` grouping of forms + explicitly-named value-kinds. */
export interface PluginNode {
  readonly _def: PluginDef;
  manifest(): string;
  toDts(options?: ToDtsOptions): string;
}

// --- Typed edit paths (plan 03) --------------------------------------------
//
// Map a `ShapeRecord` to the set of valid deep edit *paths* and the value type
// each one addresses. The engine's `set_keyword` targets a parent form + a
// key, so a user setKey/removeKey path's *terminal* IS the key and the prefix
// is the descent (`builder.ts` splits `path.slice(0,-1)` + `path.at(-1)`); a
// `replace` path points straight at the value. A `Depth`/`Dec` budget caps the
// mutual recursion so `tsc` never hits "excessively deep" — drop the default
// `6` if a very deep schema ever trips it (the `typecheck` script is the gate).
//
// Deep descent requires the container to keep its phantom marker, so it works
// through *required* nested forms / vectors-of-forms (the headline case). An
// `.optional()`/`.default()` container drops the marker, so it supports the
// terminal `[K]` (replace the whole slot) but not descent into it — use the
// low-level `edit.*` builders for those.

type Depth = [never, 0, 1, 2, 3, 4, 5, 6];
type Dec<D extends number> = D extends keyof Depth ? Depth[D] : never;

/** True when `N` is a typed nested-form field (`s.formOf`). */
type IsFormField<N> = N extends { readonly __formOf: unknown } ? true : false;
/** The inner `ShapeRecord` of a nested-form field. */
type FormFieldShape<N> = N extends FormFieldNode<infer _NS, infer _H, infer Sh> ? Sh : never;
/** The element node of a vector field (`never` for non-vectors). */
type VectorElementOf<N> = N extends VectorNode<infer E, infer _O> ? E : never;
/** True when `N` is a vector whose element is a typed nested form. */
type IsVectorOfForm<N> = VectorElementOf<N> extends FormFieldNode<string, string, ShapeRecord>
  ? true
  : false;
/** The inner `ShapeRecord` of a vector-of-form's element. */
type VectorFormShape<N> = VectorElementOf<N> extends FormFieldNode<infer _NS, infer _H, infer Sh>
  ? Sh
  : never;

/**
 * Every valid `setKey` path over `Sh`: a terminal `[K]` (set key `K` on the
 * current form), a descent `[K, …]` into a nested form, or `[K, number, …]`
 * into a vector-of-forms element, then a sub-path. The last element is the key.
 */
export type SetKeyPath<Sh extends ShapeRecord, D extends number = 6> = [D] extends [never]
  ? never
  : {
      [K in keyof Sh & string]:
        | readonly [K]
        | (IsFormField<Sh[K]> extends true
            ? readonly [K, ...SetKeyPath<FormFieldShape<Sh[K]>, Dec<D>>]
            : never)
        | (IsVectorOfForm<Sh[K]> extends true
            ? readonly [K, number, ...SetKeyPath<VectorFormShape<Sh[K]>, Dec<D>>]
            : never);
    }[keyof Sh & string];

/** The input value type addressed by a `SetKeyPath` `P` over `Sh` (the leaf key). */
export type SetKeyValue<Sh extends ShapeRecord, P extends EditPath, D extends number = 6> = [
  D,
] extends [never]
  ? never
  : P extends readonly [infer K extends string, ...infer Rest extends EditPath]
    ? K extends keyof Sh & string
      ? Rest extends readonly []
        ? InOf<Sh[K]>
        : IsFormField<Sh[K]> extends true
          ? SetKeyValue<FormFieldShape<Sh[K]>, Rest, Dec<D>>
          : IsVectorOfForm<Sh[K]> extends true
            ? Rest extends readonly [number, ...infer Tail extends EditPath]
              ? SetKeyValue<VectorFormShape<Sh[K]>, Tail, Dec<D>>
              : never
            : never
      : never
    : never;

/**
 * Every valid `removeKey` path over `Sh` — identical descent to `SetKeyPath`,
 * but the terminal `[K]` is gated to *optional-in-input* keys (optional or
 * defaulted): removing a truly-required key would invalidate the document.
 */
export type RemoveKeyPath<Sh extends ShapeRecord, D extends number = 6> = [D] extends [never]
  ? never
  : {
      [K in keyof Sh & string]:
        | (K extends OptionalInputKeys<Sh> ? readonly [K] : never)
        | (IsFormField<Sh[K]> extends true
            ? readonly [K, ...RemoveKeyPath<FormFieldShape<Sh[K]>, Dec<D>>]
            : never)
        | (IsVectorOfForm<Sh[K]> extends true
            ? readonly [K, number, ...RemoveKeyPath<VectorFormShape<Sh[K]>, Dec<D>>]
            : never);
    }[keyof Sh & string];

/**
 * Every valid `replaceAt` path over `Sh`: a path pointing straight at a value
 * to replace — a key `[K]`, a vector element `[K, number]`, or a descent into a
 * nested form / element, then such a path. Always non-empty (the engine cannot
 * replace the document root).
 */
export type ReplacePath<Sh extends ShapeRecord, D extends number = 6> = [D] extends [never]
  ? never
  : {
      [K in keyof Sh & string]:
        | readonly [K]
        | (IsFormField<Sh[K]> extends true
            ? readonly [K, ...ReplacePath<FormFieldShape<Sh[K]>, Dec<D>>]
            : never)
        | (IsVectorOfForm<Sh[K]> extends true
            ?
                | readonly [K, number]
                | readonly [K, number, ...ReplacePath<VectorFormShape<Sh[K]>, Dec<D>>]
            : never);
    }[keyof Sh & string];

/** The input value type addressed by a `ReplacePath` `P` over `Sh`. */
export type ReplaceValue<Sh extends ShapeRecord, P extends EditPath, D extends number = 6> = [
  D,
] extends [never]
  ? never
  : P extends readonly [infer K extends string, ...infer Rest extends EditPath]
    ? K extends keyof Sh & string
      ? Rest extends readonly []
        ? InOf<Sh[K]>
        : IsFormField<Sh[K]> extends true
          ? ReplaceValue<FormFieldShape<Sh[K]>, Rest, Dec<D>>
          : IsVectorOfForm<Sh[K]> extends true
            ? Rest extends readonly [number]
              ? InOf<VectorElementOf<Sh[K]>>
              : Rest extends readonly [number, ...infer Tail extends EditPath]
                ? ReplaceValue<VectorFormShape<Sh[K]>, Tail, Dec<D>>
                : never
            : never
      : never
    : never;

// --- The public `infer` helper ---------------------------------------------

/**
 * Extract a node's static output type: `s.infer<typeof Profile>`. Works
 * on any node (leaf, form, …) — reads the phantom `_out`.
 */
export type infer<T extends { readonly _out: unknown }> = T['_out'];

/** Extract a node's static *input* type (for `.parseValue`). */
export type input<T extends { readonly _in: unknown }> = T['_in'];
