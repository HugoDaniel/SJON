// Plugin model — second-host TypeScript shape.
//
// Mirrors `src/Plugin.zig` at the type level. Tracks the subset
// exercised by `conformance/cases/` plus the structural pieces the
// validator needs for diagnostic-code parity (expr-func dispatch,
// unit-shape on numeric kinds, vector-len enforcement).

import type { Diagnostic } from './diagnostics.ts';

// Optional namespace on a value-kind reference. `null` means the
// manifest wrote a bare name (`color`); a non-null value means it
// wrote `plugin/color`. Mirrors `Plugin.QualifiedRef` in src/Plugin.zig
// and the bare/qualified rule used for form heads and expr-func heads.
export interface QualifiedRef {
  readonly name: string;
  readonly namespace: string | null;
}

export type ValueType =
  | { kind: 'any' }
  | { kind: 'number' }
  | { kind: 'string' }
  | { kind: 'symbol' }
  | { kind: 'boolean' }
  | { kind: 'nil' }
  | { kind: 'vector' }
  | { kind: 'form' }
  | { kind: 'expr' }
  | { kind: 'named'; name: string; namespace: string | null };

/**
 * A key's parsed `:default` value. Mirrors `Plugin.KeySpec.Default` in
 * `src/Plugin.zig` (and lowers 1:1 to the exporter's `ModelDefault`): a
 * literal (nil/boolean/number/string/symbol/vector) or an expression snapshot.
 * Date/time literals are not representable as defaults (matching the Zig core).
 */
export type KeyDefault =
  | { readonly kind: 'nil' }
  | { readonly kind: 'boolean'; readonly value: boolean }
  | { readonly kind: 'number'; readonly value: number }
  | { readonly kind: 'string'; readonly value: string }
  | { readonly kind: 'symbol'; readonly value: string }
  | { readonly kind: 'vector'; readonly elements: readonly KeyDefault[] }
  | {
      readonly kind: 'expression';
      readonly head: string;
      readonly namespace: string | null;
      readonly argCount: number;
    };

export interface KeySpec {
  readonly name: string;
  readonly valueType: ValueType;
  readonly optional: boolean;
  /** The parsed `:default` value, or `null` if the key has none. */
  readonly default?: KeyDefault | null;
  /**
   * Inline slot-local forms (only on a `:type form` slot). A form value in
   * this slot resolves local-first against this list — a local shadows a
   * same-named global — then falls back additively to the global catalog; a
   * head matching neither is `unknown_local_form` at the slot. Mirrors
   * `Plugin.KeySpec.local_forms` in `src/Plugin.zig`. Absent when the slot
   * declared no inline forms.
   */
  readonly localForms?: readonly FormSpec[];
}

/**
 * Whether a key may be omitted: explicitly `:optional true`, OR it carries a
 * `:default` (a default fills the slot, so absence is not `missing_required_key`).
 * Mirrors `Plugin.KeySpec.effectiveOptional()` in `src/Plugin.zig`.
 */
export function effectiveOptional(key: KeySpec): boolean {
  return key.optional || key.default != null;
}

/**
 * One declared positional keyword flag. The validator matches on `name`
 * alone; `description`/`link` are optional tooling metadata carried for
 * hovers and schema export. Mirrors Zig's `PositionalSpec.FlagSet.Flag`.
 */
export interface FlagDecl {
  readonly name: string;
  readonly description?: string;
  readonly link?: string;
}

export type PositionalSpec =
  | { kind: 'none' }
  | { kind: 'any' }
  | { kind: 'kind'; name: string; namespace: string | null }
  | { kind: 'flag_set'; flags: readonly FlagDecl[] };

/**
 * One per-discriminant-value extra key set on a discriminated form.
 * Mirrors `Plugin.Variant` in `src/Plugin.zig`: `keys` are allowed (and
 * possibly required) only while the discriminant kvpair's value equals
 * `when`, and must not collide with the form's common keys or with
 * another variant's keys — a collision is `variant_key_collision` from
 * the aggregate pass, not a load-time error.
 */
export interface Variant {
  readonly when: string;
  readonly keys: readonly KeySpec[];
  /** Variant-scoped exclusive groups; alternatives name `keys`, not the
   * form's common keys. Absent when the variant declared none. */
  readonly exclusiveGroups?: readonly ExclusiveGroup[];
}

/** `:cardinality exactly-one | at-most-one`. `at_least_one` is deliberately
 * absent — that is two `optional: false` keys, no group needed. Mirrors
 * `Plugin.Cardinality`. */
export type Cardinality = 'exactly_one' | 'at_most_one';

/**
 * One alternative *bundle* in an {@link ExclusiveGroup}. `keys` names one or
 * more key names (no `:`) whose simultaneous presence constitutes "this
 * alternative is present"; multi-key bundles are atomic, so partial presence
 * is `exclusive_bundle_partial` rather than absence. Mirrors
 * `Plugin.Alternative`.
 */
export interface Alternative {
  readonly keys: readonly string[];
}

/**
 * Cross-key cardinality constraint on a {@link FormSpec} or {@link Variant} —
 * "`:notes` xor `:events`" without a per-form host hook. Mirrors
 * `Plugin.ExclusiveGroup`. Load-time invariants (checked by the loader, see
 * `resolveExclusiveGroups` in `loader.ts`): at least two alternatives, every
 * named key declared in the enclosing scope, no key in two groups on one
 * scope, and — on a form — no group naming the discriminant.
 */
export interface ExclusiveGroup {
  readonly alternatives: readonly Alternative[];
  readonly cardinality: Cardinality;
}

export interface FormSpec {
  readonly name: string;
  readonly keys: readonly KeySpec[];
  readonly positional: PositionalSpec;
  readonly open: boolean;
  /**
   * Name of the discriminant key — an entry in `keys` whose value selects
   * which `variants[i].keys` are in scope. Carried for diagnostics; the
   * validator's hot path uses `discriminantIdx`. Absent on an undiscriminated
   * form. Mirrors `Plugin.FormSpec.discriminant_name`.
   */
  readonly discriminantName?: string;
  /**
   * Index into `keys` of the discriminant key, resolved at load time. Absent
   * when the form is not discriminated **or** when `:discriminant` named a key
   * that does not exist (the loader emits `unknown_key` and leaves this unset,
   * so downstream code never indexes past `keys`). Mirrors
   * `Plugin.FormSpec.discriminant_idx`.
   */
  readonly discriminantIdx?: number;
  /** Per-`:when` extra key sets. Absent when the form declared none. */
  readonly variants?: readonly Variant[];
  /** Form-scoped exclusive groups. Absent when the form declared none. */
  readonly exclusiveGroups?: readonly ExclusiveGroup[];
  /**
   * Inline positional slot-local forms — the positional mirror of
   * `KeySpec.localForms`. A form-shaped **positional** child of this form
   * resolves local-first against this list (a local shadows a same-named
   * global), then falls back additively to the global catalog; a head
   * matching neither is `unknown_local_form` at this form's path. The
   * registry attaches whenever this is non-empty, independent of the declared
   * `positional` variant (`any` / head-set `kind`); locals with no
   * `:positional` imply `any` at load. Mirrors `Plugin.FormSpec.local_forms`
   * in `src/Plugin.zig`. Absent when the form declared no inline forms.
   */
  readonly localForms?: readonly FormSpec[];
}

export type Arity =
  | { readonly kind: 'fixed'; readonly n: number }
  | { readonly kind: 'at_least'; readonly n: number }
  | { readonly kind: 'range'; readonly min: number; readonly max: number };

export interface ExprFunc {
  readonly name: string;
  readonly arity: Arity;
  // `null` ⇒ untyped (validator skips arg-type checking). Mirrors
  // `Plugin.ExprFunc.params == null` ("opaque to validator typing").
  readonly params: readonly ValueType[] | null;
  readonly result: ValueType | null;
}

export interface UnitShape {
  readonly required: boolean;
  /** `:reject true` — a number carrying any unit suffix is rejected
   * (bare numbers only). Mutually exclusive with `required`/`allowed`. */
  readonly reject: boolean;
  readonly allowed: readonly string[];
}

// A `:min` / `:max` literal on a `(numeric-bounds …)` form. `unit` is set
// only when the literal carried a suffix; `exactInt` is true when the
// loader saw an integer-tag literal (i64 / u64) so the validator can pick
// an integer-space comparison against exact-int values, avoiding f64
// round-trip loss above 2^53.
export interface NumericBound {
  readonly value: number;
  readonly unit?: string;
  readonly exactInt: boolean;
  // Stored only when the literal was lexed as an integer tag and fits
  // in i64 (negative) or u64 (non-negative). The validator's exact-int
  // comparison path consumes this; without it we'd have to bit-twiddle
  // back from `value` (a JS number).
  readonly integerBits?: bigint;
}

export interface NumericBounds {
  readonly min?: NumericBound;
  readonly max?: NumericBound;
  readonly exclusiveMin: boolean;
  readonly exclusiveMax: boolean;
  readonly integer: boolean;
}

// GPU representation tag for a `.number` underlying. Opt-in via
// `:repr (repr-shape :type <f32|u32|i32|u16|f16>)`. Drives range /
// integrality validation (`repr_out_of_range`) and the schema export's
// `x-sjon-gpu-repr` annotation + branded TS alias. Mirrors
// `Plugin.ValueKind.Repr` in src/Plugin.zig.
export type Repr = 'f32' | 'u32' | 'i32' | 'u16' | 'f16';

// Closed set of named string formats accepted by `:string-bounds :format`.
// Mirrors `Plugin.ValueKind.StringBounds.Format` in src/Plugin.zig.
export type StringFormat = 'email' | 'uri' | 'path' | 'uuid' | 'semver';

// Length / pattern / format constraints on a `.string` underlying.
// Mirrors `Plugin.ValueKind.StringBounds` in src/Plugin.zig. All four
// fields are independent; the validator applies them cheapest-first
// (length, then format, then pattern). v1 stores `:pattern` but does
// not execute it — the validator emits `string_pattern_unsupported`
// instead of running a regex.
export interface StringBounds {
  // Inclusive lower bound on UTF-8 codepoint count.
  readonly minLen?: number;
  // Inclusive upper bound on UTF-8 codepoint count.
  readonly maxLen?: number;
  // Raw pattern source. v1 stores but does not execute.
  readonly pattern?: string;
  // Named, closed format.
  readonly format?: StringFormat;
}

/// One entry in a `MemberSet`. `name` is the only required field and
/// is what the validator matches against (byte-equality). The rest are
/// optional editor/UX metadata — empty strings count as "absent" so
/// authors only fill what they need. Mirrors
/// `Plugin.ValueKind.MemberSet.Member` in src/Plugin.zig.
export interface Member {
  readonly name: string;
  readonly label?: string;
  readonly description?: string;
  readonly deprecated?: boolean;
  readonly deprecationMessage?: string;
}

export interface ValueKind {
  readonly name: string;
  readonly underlying: 'number' | 'string' | 'vector' | 'form' | 'symbol' | 'union_of';
  readonly heads?: readonly string[];
  readonly members?: readonly Member[];
  readonly vector?: {
    readonly element: QualifiedRef;
    readonly len?: number;
    /** Inclusive element-count floor (`:min-len`). Mutually exclusive with `len`. */
    readonly minLen?: number;
    /** Inclusive element-count ceiling (`:max-len`). Mutually exclusive with `len`. */
    readonly maxLen?: number;
  };
  readonly unionOf?: { readonly alternatives: readonly QualifiedRef[] };
  readonly unit?: UnitShape;
  readonly numeric?: NumericBounds;
  /** GPU representation tag. Orthogonal to `unit`/`numeric` — all three
   * may co-exist and each is checked independently. `.number` only. */
  readonly repr?: Repr;
  readonly stringBounds?: StringBounds;
  readonly crossRef?: {
    readonly target: string;
    readonly nameKey?: string;
    readonly acyclic?: boolean;
    readonly scopeForm?: string;
    /** Provider route (manifest format 1.2): possibly-qualified
     * `CrossRefProvider` name. Absent = identity route. Mutually
     * exclusive with `nameKey` / `acyclic`, enforced at load. */
    readonly provider?: string;
    /** Provider route: kvpair key on the target form whose string value
     * is handed to the provider. Defaults to `src`. */
    readonly sourceKey?: string;
  };
}

/// A named, pure name-extractor: the second route a cross-ref can take to
/// its member set. Mirrors `Plugin.CrossRefProvider` in `src/Plugin.zig`.
///
/// This host is declarative-only, so there is no `impl` field and no
/// `wasmExportName`: `:impl` is dropped on the floor exactly as it is for
/// expr-funcs here. What this host does own is the *declaration* — the
/// catalog a `(cross-ref :provider …)` resolves against.
export interface CrossRefProvider {
  readonly name: string;
  readonly description: string;
}

export interface Plugin {
  readonly name: string;
  /// Declared `:version` from the manifest. Host compares it against
  /// `(use-plugin … :version "x")` pins and emits
  /// `plugin_version_mismatch` on disagreement (exact-string match).
  readonly version: string;
  /// Optional manifest override naming the paired wasm sidecar path.
  /// Mirrors `Plugin.wasm_file` in src/Plugin.zig.
  readonly wasmFile?: string;
  /// Optional author's stamp of the paired wasm binary's sha256:
  /// `sha256-<64 lowercase hex>`. Mirrors `Plugin.wasm_sha256`.
  readonly wasmSha256?: string;
  /// Plugin authors. Each entry may be a bare symbol or a free-form
  /// string. v1 manifests omit this field entirely.
  readonly authors: readonly string[];
  /// Declared license. SPDX identifier preferred; arbitrary strings are
  /// accepted with an advisory `license_unrecognized` warning.
  readonly license: string;
  /// Optional homepage URL — informational metadata.
  readonly homepage: string;
  /// Optional source-repository URL — informational metadata.
  readonly repository: string;
  /// Free-form keywords for discovery / categorization. Capped at
  /// `MAX_KEYWORDS = 16` with an advisory `too_many_keywords` warning.
  readonly keywords: readonly string[];
  /// Declared portable-manifest format version (e.g. `"1.0"`, `"1.1"`).
  /// Empty / absent = treat as `"1.0"`.
  readonly sjonFormat: string;
  readonly forms: readonly FormSpec[];
  readonly exprFuncs: readonly ExprFunc[];
  readonly valueKinds: readonly ValueKind[];
  readonly crossRefProviders: readonly CrossRefProvider[];
}

/// Advisory cap on `:keywords` entries. Above this, the loader emits
/// `too_many_keywords` (warning, not error). Mirrors `Plugin.MAX_KEYWORDS`.
export const MAX_KEYWORDS = 16;

/// Highest portable-manifest format version this host understands.
/// Mirrors `Plugin.SUPPORTED_SJON_FORMAT`. Bumped on incompatible spec
/// changes.
export const SUPPORTED_SJON_FORMAT = '1.2';

export interface Schema {
  readonly plugins: readonly Plugin[];
}

// Mirrors `Schema.MAX_KIND_DEPTH` in `src/Schema.zig`. Caps named-kind
// chain resolution depth in matchType, so a self-vectoring kind bottoms
// out with `recursion_depth` instead of unbounded recursion.
export const MAX_KIND_DEPTH = 8;

// Mirrors `Plugin.MAX_FORM_KEYS` in `src/Plugin.zig`. The Zig validator's
// required-key bitset is u64-backed; over-cap forms are rejected at
// manifest-load time with `too_many_keys`.
export const MAX_FORM_KEYS = 64;

// Mirrors `Plugin.MAX_LOCAL_FORM_DEPTH` in `src/Plugin.zig`. Bounds the
// FormSpec→KeySpec→FormSpec slot-local nesting the loader will build.
export const MAX_LOCAL_FORM_DEPTH = 8;

/// Tri-state lookup result. Mirrors `FormLookup` / `ExprLookup` /
/// `ValueKindLookup` in `src/Schema.zig`. Bare lookups can collide
/// across plugins; qualified lookups (`ns/name`) cannot.
export type Lookup<T> =
  | { kind: 'found'; value: T }
  | { kind: 'not_found' }
  | { kind: 'ambiguous'; plugins: readonly Plugin[] };

export function lookupForm(schema: Schema, name: string, ns: string | null): Lookup<FormSpec> {
  if (ns) {
    for (const p of schema.plugins) {
      if (p.name !== ns) continue;
      for (const f of p.forms) {
        if (f.name === name) return { kind: 'found', value: f };
      }
      return { kind: 'not_found' };
    }
    return { kind: 'not_found' };
  }
  let first: { plugin: Plugin; form: FormSpec } | null = null;
  const collisions: Plugin[] = [];
  for (const p of schema.plugins) {
    for (const f of p.forms) {
      if (f.name !== name) continue;
      if (!first) first = { plugin: p, form: f };
      else {
        if (collisions.length === 0) collisions.push(first.plugin);
        collisions.push(p);
      }
      break;
    }
  }
  if (collisions.length > 0) return { kind: 'ambiguous', plugins: collisions };
  if (first) return { kind: 'found', value: first.form };
  return { kind: 'not_found' };
}

export function lookupExprFunc(schema: Schema, name: string, ns: string | null): Lookup<ExprFunc> {
  if (ns) {
    for (const p of schema.plugins) {
      if (p.name !== ns) continue;
      for (const f of p.exprFuncs) {
        if (f.name === name) return { kind: 'found', value: f };
      }
      return { kind: 'not_found' };
    }
    return { kind: 'not_found' };
  }
  let first: { plugin: Plugin; func: ExprFunc } | null = null;
  const collisions: Plugin[] = [];
  for (const p of schema.plugins) {
    for (const f of p.exprFuncs) {
      if (f.name !== name) continue;
      if (!first) first = { plugin: p, func: f };
      else {
        if (collisions.length === 0) collisions.push(first.plugin);
        collisions.push(p);
      }
      break;
    }
  }
  if (collisions.length > 0) return { kind: 'ambiguous', plugins: collisions };
  if (first) return { kind: 'found', value: first.func };
  return { kind: 'not_found' };
}

export function lookupValueKind(
  schema: Schema,
  name: string,
  ns: string | null,
): Lookup<ValueKind> {
  if (ns) {
    for (const p of schema.plugins) {
      if (p.name !== ns) continue;
      for (const v of p.valueKinds) {
        if (v.name === name) return { kind: 'found', value: v };
      }
      return { kind: 'not_found' };
    }
    return { kind: 'not_found' };
  }
  let first: { plugin: Plugin; kind: ValueKind } | null = null;
  const collisions: Plugin[] = [];
  for (const p of schema.plugins) {
    for (const v of p.valueKinds) {
      if (v.name !== name) continue;
      if (!first) first = { plugin: p, kind: v };
      else {
        if (collisions.length === 0) collisions.push(first.plugin);
        collisions.push(p);
      }
      break;
    }
  }
  if (collisions.length > 0) return { kind: 'ambiguous', plugins: collisions };
  if (first) return { kind: 'found', value: first.kind };
  return { kind: 'not_found' };
}

export function checkArity(arity: Arity, n: number): boolean {
  switch (arity.kind) {
    case 'fixed':
      return n === arity.n;
    case 'at_least':
      return n >= arity.n;
    case 'range':
      return n >= arity.min && n <= arity.max;
  }
}

export function paramTypeAt(fn: ExprFunc, i: number): ValueType | null {
  if (fn.params && i < fn.params.length) return fn.params[i]!;
  return null;
}

// ---------------------------------------------------------------------------
// Schema-aggregate cross-ref resolution.
//
// Mirrors `Schema.validateCrossRefs` in `src/Schema.zig`. Run once after
// manifest load, before input validation, so unresolved cross-ref targets
// and scopes surface as schema-phase diagnostics instead of confusing
// per-input failures.
// ---------------------------------------------------------------------------

const PRIMITIVE_TYPE_NAMES: ReadonlySet<string> = new Set([
  'any',
  'number',
  'string',
  'symbol',
  'boolean',
  'nil',
  'vector',
  'form',
  'expr',
]);

type FormResolution =
  | { kind: 'found'; plugin: Plugin; form: FormSpec }
  | { kind: 'not_found' }
  | { kind: 'ambiguous'; plugins: Plugin[] };

function resolveForm(schema: Schema, raw: string): FormResolution {
  let ns: string | null = null;
  let name = raw;
  const slash = raw.indexOf('/');
  if (slash >= 0) {
    ns = raw.slice(0, slash);
    name = raw.slice(slash + 1);
  }
  if (ns) {
    for (const p of schema.plugins) {
      if (p.name !== ns) continue;
      for (const f of p.forms) {
        if (f.name === name) return { kind: 'found', plugin: p, form: f };
      }
      return { kind: 'not_found' };
    }
    return { kind: 'not_found' };
  }
  let first: { plugin: Plugin; form: FormSpec } | null = null;
  const collisions: Plugin[] = [];
  for (const p of schema.plugins) {
    for (const f of p.forms) {
      if (f.name !== name) continue;
      if (!first) first = { plugin: p, form: f };
      else {
        if (collisions.length === 0) collisions.push(first.plugin);
        collisions.push(p);
      }
      break;
    }
  }
  if (collisions.length > 0) return { kind: 'ambiguous', plugins: collisions };
  if (first) return { kind: 'found', plugin: first.plugin, form: first.form };
  return { kind: 'not_found' };
}

/// True if `vt` resolves to a symbol-typed slot. Matches the Zig
/// `isSymbolValueType` — direct `symbol`/`any`, or a single-hop `named`
/// reference whose value-kind has `underlying === 'symbol'`.
type ProviderResolution =
  | { kind: 'found'; plugin: Plugin; provider: CrossRefProvider }
  | { kind: 'not_found' }
  | { kind: 'ambiguous'; plugins: Plugin[] };

/// Resolve a possibly-qualified provider name against every plugin's
/// fourth catalog. Same bare-or-qualified rule as `resolveForm`; mirrors
/// `Schema.lookupCrossRefProvider` in `src/Schema.zig`.
function resolveProvider(schema: Schema, raw: string): ProviderResolution {
  let ns: string | null = null;
  let name = raw;
  const slash = raw.indexOf('/');
  if (slash >= 0) {
    ns = raw.slice(0, slash);
    name = raw.slice(slash + 1);
  }
  if (ns) {
    for (const p of schema.plugins) {
      if (p.name !== ns) continue;
      for (const cp of p.crossRefProviders) {
        if (cp.name === name) return { kind: 'found', plugin: p, provider: cp };
      }
      return { kind: 'not_found' };
    }
    return { kind: 'not_found' };
  }
  let first: { plugin: Plugin; provider: CrossRefProvider } | null = null;
  const collisions: Plugin[] = [];
  for (const p of schema.plugins) {
    for (const cp of p.crossRefProviders) {
      if (cp.name !== name) continue;
      if (!first) first = { plugin: p, provider: cp };
      else {
        if (collisions.length === 0) collisions.push(first.plugin);
        collisions.push(p);
      }
      break;
    }
  }
  if (collisions.length > 0) return { kind: 'ambiguous', plugins: collisions };
  if (first) return { kind: 'found', plugin: first.plugin, provider: first.provider };
  return { kind: 'not_found' };
}

/// String twin of `isSymbolValueType`, for the provider route's
/// `:source-key`. Mirrors `isStringValueType` in `src/Schema.zig`:
/// `any` matches, a `named` reference resolves one hop, and a
/// `stringBounds`-refined kind counts (a refinement narrows a string
/// rather than replacing it).
function isStringValueType(schema: Schema, vt: ValueType): boolean {
  switch (vt.kind) {
    case 'string':
    case 'any':
      return true;
    case 'named': {
      const n = vt.name;
      if (n === 'string' || n === 'any') return true;
      const k = lookupValueKind(schema, n, vt.namespace);
      return k.kind === 'found' && k.value.underlying === 'string';
    }
    default:
      return false;
  }
}

function isSymbolValueType(schema: Schema, vt: ValueType): boolean {
  switch (vt.kind) {
    case 'symbol':
    case 'any':
      return true;
    case 'named': {
      const n = vt.name;
      if (n === 'symbol' || n === 'any') return true;
      const k = lookupValueKind(schema, n, vt.namespace);
      return k.kind === 'found' && k.value.underlying === 'symbol';
    }
    default:
      return false;
  }
}

/// Walk a key's `valueType` to see if it loops back to `targetKind`.
/// Matches `selfEdgeShape` in `src/Schema.zig`: at most one vector hop,
/// bounded by `MAX_KIND_DEPTH`. Returns true when the kind has a
/// self-edge (the acyclic flag has something to walk).
function selfEdges(schema: Schema, vt: ValueType, targetKind: string): boolean {
  let current: ValueType = vt;
  let sawVector = false;
  for (let depth = 0; depth < MAX_KIND_DEPTH; depth++) {
    if (current.kind !== 'named') return false;
    const name = current.name;
    if (name === targetKind) return true;
    if (PRIMITIVE_TYPE_NAMES.has(name)) return false;
    const vk = lookupValueKind(schema, name, current.namespace);
    if (vk.kind !== 'found') return false;
    if (vk.value.vector) {
      if (sawVector) return false;
      sawVector = true;
      const elem = vk.value.vector.element;
      if (elem.name === targetKind) return true;
      if (PRIMITIVE_TYPE_NAMES.has(elem.name)) return false;
      current = { kind: 'named', name: elem.name, namespace: elem.namespace };
      continue;
    }
    return false;
  }
  return false;
}

const ZERO_SPAN = { start: 0, end: 0 } as const;

function aggregatePath(pluginName: string, kindName: string): readonly string[] {
  return [pluginName, kindName, 'cross-ref'];
}

/** `[<plugin>, <form-or-kind>, <leaf>]` — the shape every aggregate-phase
 *  diagnostic is pathed by. The span is `{0,0}` throughout: this phase runs
 *  over the *aggregated* catalog and has no access to the originating
 *  manifest's source tree. Mirrors `formAggregatePath` in `src/Schema.zig`. */
function formAggregatePath(pluginName: string, formName: string, leaf: string): readonly string[] {
  return [pluginName, formName, leaf];
}

/** Everything about a `(cross-ref …)` that decides *what ends up in the
 *  registry* for its target, canonicalised. Deliberately not the whole
 *  cross-ref: `:acyclic` is a check run over the finished registry, not an
 *  input to building it, so two kinds differing only in that agree on the
 *  member set. Mirrors `RegistrySpec` in `src/Schema.zig`. */
interface RegistrySpec {
  /** The kind's identity, for the message. Not compared. */
  readonly plugin: string;
  readonly kind: string;
  /** Canonical `<plugin>/<provider>`, or null on the identity route. */
  readonly provider: string | null;
  /** `:name-key` on the identity route, `:source-key` on the provider one —
   *  the one the route actually reads. Folding them into a single field is
   *  what keeps a provider spec's inert default `:name-key` from
   *  registering as a difference. */
  readonly key: string;
  /** Canonical `<plugin>/<form>`, or null for document-wide. */
  readonly scope: string | null;
}

function registrySpecsAgree(a: RegistrySpec, b: RegistrySpec): boolean {
  return a.provider === b.provider && a.key === b.key && a.scope === b.scope;
}

/** How a spec builds its set, phrased for the collapse message. */
function describeRegistrySpec(s: RegistrySpec): string {
  const route =
    s.provider === null
      ? `\`:name-key ${s.key}\``
      : `\`:provider ${s.provider}\` over \`:source-key ${s.key}\``;
  return s.scope === null ? route : `${route} scoped to \`${s.scope}\``;
}

/** Canonical `<plugin>/<form>` for a possibly-qualified spelling, or null
 *  when it doesn't resolve cleanly. Mirrors `Schema.canonicalFormName`. */
function canonicalFormName(schema: Schema, spelling: string): string | null {
  const hit = resolveForm(schema, spelling);
  return hit.kind === 'found' ? `${hit.plugin.name}/${hit.form.name}` : null;
}

/** The provider vocabulary's twin. Mirrors `Schema.canonicalProviderName`. */
function canonicalProviderName(schema: Schema, spelling: string): string | null {
  const hit = resolveProvider(schema, spelling);
  return hit.kind === 'found' ? `${hit.plugin.name}/${hit.provider.name}` : null;
}

export function validateCrossRefs(schema: Schema): Diagnostic[] {
  const out: Diagnostic[] = [];
  // Replays `collectCrossRefTargets`' first-wins map in the same
  // plugin × value-kind order, so "the first spec" here is the one the
  // registry is actually built from. Mirrors `winners` in `validateCrossRefs`
  // (`src/Schema.zig`).
  const winners = new Map<string, RegistrySpec>();
  for (const plugin of schema.plugins) {
    for (const kind of plugin.valueKinds) {
      const cr = kind.crossRef;
      if (!cr) continue;

      const target = resolveForm(schema, cr.target);
      if (target.kind === 'not_found') {
        out.push({
          code: 'unknown_cross_ref_target',
          message: `value-kind \`${kind.name}\` cross-ref \`:target ${cr.target}\` does not resolve to any form`,
          path: aggregatePath(plugin.name, kind.name),
          span: ZERO_SPAN,
          severity: 'err',
        });
      } else if (target.kind === 'ambiguous') {
        const list = target.plugins.map((p) => p.name).join(', ');
        const bareName = cr.target.includes('/') ? cr.target.split('/')[1]! : cr.target;
        out.push({
          code: 'ambiguous_cross_ref_target',
          message: `value-kind \`${kind.name}\` cross-ref \`:target ${cr.target}\` is ambiguous — defined by [${list}]; qualify with \`<ns>/${bareName}\``,
          path: aggregatePath(plugin.name, kind.name),
          span: ZERO_SPAN,
          severity: 'err',
        });
      } else {
        const targetForm = target.form;
        // Exactly one of the two routes' keys is checked — the loader has
        // already rejected a spec claiming both, so this is a dispatch,
        // not a precedence rule.
        if (cr.provider === undefined) {
          const nameKey = cr.nameKey ?? 'name';
          let foundKey = false;
          let symbolTyped = false;
          for (const k of targetForm.keys) {
            if (k.name !== nameKey) continue;
            foundKey = true;
            symbolTyped = isSymbolValueType(schema, k.valueType);
            break;
          }
          if (!foundKey || !symbolTyped) {
            out.push({
              code: 'cross_ref_name_key_unknown',
              message: `value-kind \`${kind.name}\` cross-ref \`:name-key ${nameKey}\` is not a symbol-typed key on form \`${targetForm.name}\``,
              path: aggregatePath(plugin.name, kind.name),
              span: ZERO_SPAN,
              severity: 'err',
            });
          }
        } else {
          const sourceKey = cr.sourceKey ?? 'src';
          let foundKey = false;
          let stringTyped = false;
          for (const k of targetForm.keys) {
            if (k.name !== sourceKey) continue;
            foundKey = true;
            stringTyped = isStringValueType(schema, k.valueType);
            break;
          }
          if (!foundKey || !stringTyped) {
            out.push({
              code: 'cross_ref_source_key_unknown',
              message: `value-kind \`${kind.name}\` cross-ref \`:source-key ${sourceKey}\` is not a string-typed key on form \`${targetForm.name}\``,
              path: aggregatePath(plugin.name, kind.name),
              span: ZERO_SPAN,
              severity: 'err',
            });
          }
        }
        if (cr.acyclic) {
          let hasSelfEdge = false;
          for (const k of targetForm.keys) {
            if (selfEdges(schema, k.valueType, kind.name)) {
              hasSelfEdge = true;
              break;
            }
          }
          if (!hasSelfEdge) {
            out.push({
              code: 'acyclic_without_self_edge',
              message: `value-kind \`${kind.name}\` declares \`:acyclic true\` but form \`${targetForm.name}\` has no key whose type resolves to \`${kind.name}\` — the cycle check has no edges to follow`,
              path: aggregatePath(plugin.name, kind.name),
              span: ZERO_SPAN,
              severity: 'err',
            });
          }
        }
      }

      // `:provider` must resolve to exactly one declared provider.
      // Independent of whether `:target` resolved — two authoring
      // mistakes deserve two diagnostics.
      if (cr.provider !== undefined) {
        const prov = resolveProvider(schema, cr.provider);
        if (prov.kind === 'not_found') {
          out.push({
            code: 'unknown_cross_ref_provider',
            message: `value-kind \`${kind.name}\` cross-ref \`:provider ${cr.provider}\` does not resolve to any declared provider`,
            path: aggregatePath(plugin.name, kind.name),
            span: ZERO_SPAN,
            severity: 'err',
          });
        } else if (prov.kind === 'ambiguous') {
          const list = prov.plugins.map((p) => p.name).join(', ');
          const bareName = cr.provider.includes('/') ? cr.provider.split('/')[1]! : cr.provider;
          out.push({
            code: 'ambiguous_cross_ref_provider',
            message: `value-kind \`${kind.name}\` cross-ref \`:provider ${cr.provider}\` is ambiguous — defined by [${list}]; qualify with \`<ns>/${bareName}\``,
            path: aggregatePath(plugin.name, kind.name),
            span: ZERO_SPAN,
            severity: 'err',
          });
        }
      }

      if (cr.scopeForm) {
        const scope = resolveForm(schema, cr.scopeForm);
        if (scope.kind === 'not_found') {
          out.push({
            code: 'unknown_cross_ref_scope',
            message: `value-kind \`${kind.name}\` cross-ref \`:scope ${cr.scopeForm}\` does not resolve to any form`,
            path: aggregatePath(plugin.name, kind.name),
            span: ZERO_SPAN,
            severity: 'err',
          });
        } else if (scope.kind === 'ambiguous') {
          const list = scope.plugins.map((p) => p.name).join(', ');
          const bareName = cr.scopeForm.includes('/') ? cr.scopeForm.split('/')[1]! : cr.scopeForm;
          out.push({
            code: 'ambiguous_cross_ref_scope',
            message: `value-kind \`${kind.name}\` cross-ref \`:scope ${cr.scopeForm}\` is ambiguous — defined by [${list}]; qualify with \`<ns>/${bareName}\``,
            path: aggregatePath(plugin.name, kind.name),
            span: ZERO_SPAN,
            severity: 'err',
          });
        }
      }

      // One target form, one member set. A second cross-ref naming the
      // same target contributes nothing, so when the two specs disagree
      // the loser's references end up checked against the winner's names.
      // Skips exactly what `collectCrossRefTargets` skips: a spec the
      // registry never sees can neither win nor lose a collapse, and has
      // already been reported for the reason it was dropped.
      const canonicalTarget = canonicalFormName(schema, cr.target);
      if (canonicalTarget === null) continue;
      let provider: string | null = null;
      if (cr.provider !== undefined) {
        provider = canonicalProviderName(schema, cr.provider);
        if (provider === null) continue;
      }
      const mine: RegistrySpec = {
        plugin: plugin.name,
        kind: kind.name,
        provider,
        key: provider === null ? (cr.nameKey ?? 'name') : (cr.sourceKey ?? 'src'),
        scope: cr.scopeForm ? canonicalFormName(schema, cr.scopeForm) : null,
      };
      const won = winners.get(canonicalTarget);
      if (won === undefined) {
        winners.set(canonicalTarget, mine);
        continue;
      }
      if (registrySpecsAgree(won, mine)) continue;
      out.push({
        code: 'cross_ref_target_collapse',
        message:
          `value-kind \`${kind.name}\` cross-references form \`${canonicalTarget}\`, whose members ` +
          `are already collected by value-kind \`${won.kind}\` in plugin \`${won.plugin}\` using ` +
          `${describeRegistrySpec(won)}; this kind's ${describeRegistrySpec(mine)} is ignored, and ` +
          `its references are checked against the other kind's names`,
        path: formAggregatePath(plugin.name, kind.name, 'cross-ref'),
        span: ZERO_SPAN,
        severity: 'warning',
      });
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Schema-aggregate union resolution.
//
// Mirrors `Schema.validateUnions` in `src/Schema.zig`. Resolves every
// `:union` alternative against the aggregated value-kind catalog, so an
// unresolvable / colliding / itself-a-union alternative is a schema-phase
// diagnostic instead of a confusing per-input dispatch failure. Nesting is
// rejected outright so union dispatch stays a flat loop.
// ---------------------------------------------------------------------------

export function validateUnions(schema: Schema): Diagnostic[] {
  const out: Diagnostic[] = [];
  for (const plugin of schema.plugins) {
    for (const kind of plugin.valueKinds) {
      const us = kind.unionOf;
      if (!us) continue;
      for (const alt of us.alternatives) {
        // Primitive shortcuts always resolve to themselves, never to a
        // union — skip the catalog lookup.
        if (PRIMITIVE_TYPE_NAMES.has(alt.name)) continue;
        const found = lookupValueKind(schema, alt.name, alt.namespace);
        const path = formAggregatePath(plugin.name, kind.name, 'union');
        switch (found.kind) {
          case 'not_found':
            out.push({
              code: 'unknown_element_kind',
              message: `value-kind \`${kind.name}\` \`:union\` alternative \`${alt.name}\` does not resolve to any value-kind`,
              path,
              span: ZERO_SPAN,
              severity: 'err',
            });
            break;
          case 'ambiguous': {
            // Union alternatives name the first actual claimant in the
            // "qualify with" hint (not the `<ns>` placeholder the cross-ref
            // sites use), and drop the hint entirely when the collision list
            // is empty.
            const claimants = found.plugins;
            const list = claimants.map((p) => p.name).join(', ');
            const suffix =
              claimants.length > 0 ? `; qualify with \`${claimants[0]!.name}/${alt.name}\`` : '';
            out.push({
              code: 'ambiguous_element_kind',
              message: `value-kind \`${kind.name}\` \`:union\` alternative \`${alt.name}\` is ambiguous — defined by [${list}]${suffix}`,
              path,
              span: ZERO_SPAN,
              severity: 'err',
            });
            break;
          }
          case 'found':
            if (found.value.underlying === 'union_of') {
              out.push({
                code: 'nested_union',
                message: `value-kind \`${kind.name}\` \`:union\` alternative \`${alt.name}\` is itself a union — nesting is not allowed`,
                path,
                span: ZERO_SPAN,
                severity: 'err',
              });
            }
            break;
        }
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Schema-aggregate discriminated-form checks.
//
// Mirrors `Schema.validateForms` in `src/Schema.zig`. Three questions per
// discriminated form, all answerable before any document is read: does the
// discriminant resolve to a closed enum, is every `(variant :when …)` a
// member of it, and does one key name mean one slot.
// ---------------------------------------------------------------------------

/**
 * Resolve a discriminant key's type to the member list of a closed symbol
 * enum, or `null` when it is not one — a primitive `symbol` slot, an
 * unresolvable name, a non-`symbol` underlying, or an empty `:members`.
 * Mirrors `resolveDiscriminantMembers` in `src/Schema.zig`.
 */
function resolveDiscriminantMembers(schema: Schema, vt: ValueType): readonly Member[] | null {
  if (vt.kind !== 'named') return null;
  const found = lookupValueKind(schema, vt.name, vt.namespace);
  if (found.kind !== 'found') return null;
  if (found.value.underlying !== 'symbol') return null;
  const members = found.value.members;
  if (!members || members.length === 0) return null;
  return members;
}

export function validateForms(schema: Schema): Diagnostic[] {
  const out: Diagnostic[] = [];
  for (const plugin of schema.plugins) {
    for (const form of plugin.forms) {
      const idx = form.discriminantIdx;
      if (idx === undefined) continue;
      const dkey = form.keys[idx];
      if (!dkey) continue; // defensive: the loader should not produce this

      const members = resolveDiscriminantMembers(schema, dkey.valueType);
      if (members === null) {
        out.push({
          code: 'discriminant_not_closed_enum',
          message: `form \`${form.name}\` discriminant \`:${dkey.name}\` must resolve to a value-kind with \`:underlying symbol\` and a non-empty \`:members\` set`,
          path: formAggregatePath(plugin.name, form.name, 'discriminant'),
          span: ZERO_SPAN,
          severity: 'err',
        });
        // Without a closed enum there is no membership to test; stop here
        // rather than pile variant noise on top of the root cause.
        continue;
      }

      const variants = form.variants ?? [];
      for (const v of variants) {
        if (members.some((m) => m.name === v.when)) continue;
        out.push({
          code: 'unknown_discriminant_value',
          message: `form \`${form.name}\` variant \`:when ${v.when}\` is not a member of discriminant \`:${dkey.name}\``,
          path: formAggregatePath(plugin.name, form.name, 'variant'),
          span: ZERO_SPAN,
          severity: 'err',
        });
      }

      // Key-name collisions: every variant key must be distinct from every
      // common key, and from every prior variant key. One name = one slot.
      for (let vi = 0; vi < variants.length; vi++) {
        const v = variants[vi]!;
        for (const vk of v.keys) {
          for (const ck of form.keys) {
            if (vk.name !== ck.name) continue;
            out.push({
              code: 'variant_key_collision',
              message: `form \`${form.name}\` variant \`:when ${v.when}\` redeclares key \`:${vk.name}\` (also in common keys)`,
              path: formAggregatePath(plugin.name, form.name, 'variant'),
              span: ZERO_SPAN,
              severity: 'err',
            });
          }
          for (let pi = 0; pi < vi; pi++) {
            const prior = variants[pi]!;
            for (const pk of prior.keys) {
              if (vk.name !== pk.name) continue;
              out.push({
                code: 'variant_key_collision',
                message: `form \`${form.name}\` variant \`:when ${v.when}\` redeclares key \`:${vk.name}\` (also in variant \`:when ${prior.when}\`)`,
                path: formAggregatePath(plugin.name, form.name, 'variant'),
                span: ZERO_SPAN,
                severity: 'err',
              });
            }
          }
        }
      }
    }
  }
  return out;
}
