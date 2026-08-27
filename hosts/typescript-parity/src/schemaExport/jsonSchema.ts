// Model → JSON Schema 2020-12 bytes — TypeScript port of
// `src/SchemaExport/JsonSchema.zig`.
//
// Pure consumer of the IR. Mapping rules live in the per-shape
// helpers; this file does not classify shapes or emit warnings — the
// lowering pass handled that. Output is deterministic: form definitions
// in plugin × form declaration order, keys alphabetically inside each
// form, `oneOf` over every form, `$defs` keyed by `form.<plugin>.<head>`
// and `kind.<plugin>.<name>`.
//
// Structural parity with Zig:
//
//   * Same top-level shape (`$schema` / `x-sjon-export-version` /
//     `x-sjon-export-warnings` / `$defs` / `oneOf`)
//   * Same `$defs` key scheme (`form.<plugin>.<head>`)
//   * Same per-shape mapping (the §4 table in docs/SCHEMA_EXPORT.md)
//   * `JSON.stringify(_, null, 2)` formatting (Zig also uses 2-space
//     indent; key ordering matches because we emit objects in the same
//     declaration order)
//
// Variants (discriminator → allOf+if/then), exclusive groups (oneOf /
// not:{allOf}) and union-of (anyOf) are all emitted here now that
// `loader.ts` parses them, and `test/schemaExport.test.ts` compares the
// `allOf` composition and `x-sjon-*` annotations against the Zig goldens.
// End-to-end byte agreement is still out of reach for reasons below this
// file: the loader does not read `:description`, and an untyped vector slot
// omits the `items: {}` the Zig exporter writes.

import type { Member } from '../plugin.ts';
import type {
  Model,
  ModelExclusiveGroup,
  ModelForm,
  ModelKey,
  ModelMember,
  ModelNumericBounds,
  ModelPlugin,
  ModelStringBounds,
  ModelUnitShape,
  ModelFormRef,
  ModelValueShape,
  ModelVariant,
} from './model.ts';
import { anyBoundedInSet, headSetHasFloor, isBoundedRef, isBoundedSet, refBody } from './model.ts';
import type { Warning } from './warnings.ts';
import { assertNever, isRecord } from '../internal.ts';

interface EmitContext {
  /** When set, only emit `$defs` / `oneOf` for the named plugin. */
  readonly filterPlugin: string | null;
  /**
   * Plugin currently being emitted. Set by `buildForm` (via a spread copy)
   * so the `form_locals` arm of `buildShape` can reuse `buildForm` for each
   * inline local — which needs the plugin for the `$ns` const. Mirrors the
   * Zig `current_plugin` threadlocal in `JsonSchema.zig`. `null` outside a
   * form (never read there — `form_locals` is only reached via a key).
   */
  readonly plugin: ModelPlugin | null;
}

/** Aggregated emit — every plugin in scope. */
export function emit(model: Model, warnings: readonly Warning[]): string {
  return emitWithContext(model, warnings, { filterPlugin: null, plugin: null });
}

/** Per-plugin emit — narrow to one plugin's forms. */
export function emitForPlugin(
  model: Model,
  plugin: ModelPlugin,
  warnings: readonly Warning[],
): string {
  return emitWithContext(model, warnings, { filterPlugin: plugin.name, plugin: null });
}

function emitWithContext(model: Model, warnings: readonly Warning[], ctx: EmitContext): string {
  const root: Record<string, unknown> = {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    'x-sjon-export-version': model.version,
  };
  if (warnings.length > 0) {
    root['x-sjon-export-warnings'] = warnings.map(serializeWarning);
  }
  const defs: Record<string, unknown> = {};
  const oneOf: unknown[] = [];
  for (const p of model.plugins) {
    if (ctx.filterPlugin && p.name !== ctx.filterPlugin) continue;
    for (const f of p.forms) {
      defs[`form.${p.name}.${f.name}`] = buildForm(p, f, ctx);
      oneOf.push({ $ref: `#/$defs/form.${p.name}.${f.name}` });
    }
  }
  root['$defs'] = defs;
  root['oneOf'] = oneOf.length > 0 ? oneOf : [{ not: {} }];
  return JSON.stringify(root, null, 2) + '\n';
}

function serializeWarning(w: Warning): Record<string, unknown> {
  const out: Record<string, unknown> = {
    severity: w.severity,
    code: w.code,
    message: w.message,
  };
  if (w.pluginName) out['plugin'] = w.pluginName;
  if (w.formName) out['form'] = w.formName;
  if (w.keyName) out['key'] = w.keyName;
  if (w.kindName) out['kind'] = w.kindName;
  return out;
}

function buildForm(
  plugin: ModelPlugin,
  form: ModelForm,
  ctx: EmitContext,
): Record<string, unknown> {
  // Make this plugin visible to the `form_locals` arm of `buildShape`,
  // which reuses `buildForm` for each inline local (same plugin).
  const formCtx: EmitContext = { ...ctx, plugin };
  const properties: Record<string, unknown> = {
    $form: { const: form.name },
    $ns: { const: plugin.name },
  };
  // Keys sorted alphabetically for deterministic diffs.
  const sortedKeys = [...form.keys].sort((a, b) => a.name.localeCompare(b.name));
  for (const k of sortedKeys) {
    properties[escapeFieldName(k.name)] = buildKey(k, formCtx);
  }
  switch (form.positional.kind) {
    case 'none':
      break;
    case 'any':
      properties['$children'] = { type: 'array' };
      break;
    case 'kind': {
      const children: Record<string, unknown> = {
        type: 'array',
        items: buildShape(form.positional.shape, formCtx),
      };
      const bounds = buildChildrenBounds(form.positional.shape, formCtx);
      if (bounds) children['allOf'] = bounds;
      properties['$children'] = children;
      break;
    }
    default:
      assertNever(form.positional);
  }
  const required: string[] = ['$form'];
  for (const k of form.keys) {
    if (!k.optional) required.push(escapeFieldName(k.name));
  }
  // A positional floor also makes `$children` required. The JSON bridge
  // omits `$children` entirely for a childless form, so `minContains` —
  // which lives inside the `$children` subschema — is unreachable for the
  // one document that breaches the floor hardest. Ceilings need nothing:
  // an absent array cannot exceed one. Mirrors Zig's `shapeHasChildFloor`.
  if (form.positional.kind === 'kind' && shapeHasChildFloor(form.positional.shape)) {
    required.push('$children');
  }
  const out: Record<string, unknown> = { type: 'object', properties, required };
  // `dependentRequired` is 2020-12's exact encoding of `:requires`. Emitted
  // only when some key declares one, so a dependency-free schema serializes
  // byte-identically to before. Mirrors the Zig writer's placement — right
  // after `required`, before the discriminated-form `allOf`.
  const dependentRequired: Record<string, string[]> = {};
  for (const k of form.keys) {
    if (k.requires.length === 0) continue;
    dependentRequired[escapeFieldName(k.name)] = k.requires.map(escapeFieldName);
  }
  if (Object.keys(dependentRequired).length > 0) {
    out['dependentRequired'] = dependentRequired;
  }

  // Discriminated forms compose per-variant overlays via `allOf` of
  // `if`/`then`; exclusive groups join the same chain as `oneOf`
  // (exactly-one) or `not:{allOf}` (at-most-one). Because a `then` branch
  // introduces properties the base object does not list, the schema closes
  // with `unevaluatedProperties` instead of `additionalProperties` — the
  // latter cannot see what a matched `then` evaluated and would reject every
  // variant key. Mirrors `src/SchemaExport/JsonSchema.zig`.
  const enforceable = (form.exclusiveGroups ?? []).filter(isEnforceableGroup);
  if (form.discriminator || enforceable.length > 0) {
    const allOf: Record<string, unknown>[] = [];
    for (const v of form.discriminator?.variants ?? []) {
      allOf.push(buildVariantOverlay(form.discriminator!.keyName, v, formCtx));
    }
    for (const g of enforceable) allOf.push(buildExclusiveGroup(g));
    out['allOf'] = allOf;
    out['unevaluatedProperties'] = form.open;
  } else {
    out['additionalProperties'] = form.open;
  }

  if (form.discriminator) {
    out['x-sjon-discriminant'] = {
      key: form.discriminator.keyName,
      variants: form.discriminator.variants.map((v) => ({
        // The manifest's own spelling: one value bare, several as a list —
        // so a single-value variant's annotation is unchanged.
        when: v.when.length === 1 ? v.when[0]! : [...v.when],
        keys: v.keys.map((k) => k.name),
      })),
    };
  }
  // Every group is annotated, including one too degenerate to enforce: the
  // annotation is the record of what the source declared, not of what JSON
  // Schema managed to express.
  if (form.exclusiveGroups.length > 0) {
    out['x-sjon-exclusive-groups'] = form.exclusiveGroups.map((g) => ({
      cardinality: g.cardinality,
      alternatives: g.alternatives.map((alt) => [...alt]),
    }));
  }
  // `:positional (flag-set …)` rides through as annotation-only metadata
  // — the `$children` shape above widened to a plain array, so this is
  // the only place the declared flag names + metadata survive.
  if (form.positionalFlags) {
    out['x-sjon-positional-flags'] = form.positionalFlags.map((f) => {
      const anno: Record<string, unknown> = { name: f.name };
      // Mirror the Zig emitter (`src/SchemaExport/JsonSchema.zig`): description
      // is gated on non-empty (`len > 0`), so an explicit `:description ""`
      // is omitted — but `link` rides on presence alone, so `:link ""`
      // survives as `""`. Keep the asymmetry exactly, or the annotation
      // diverges from the reference host on empty-string metadata.
      if (f.description !== undefined && f.description.length > 0)
        anno['description'] = f.description;
      if (f.link !== undefined) anno['link'] = f.link;
      return anno;
    });
  }
  return out;
}

/** A group is structurally encodable when it has at least two alternatives
 *  and no empty bundle. A degenerate group still rides through as an
 *  annotation — it just contributes nothing to `allOf`. */
function isEnforceableGroup(g: ModelExclusiveGroup): boolean {
  return g.alternatives.length >= 2 && g.alternatives.every((alt) => alt.length > 0);
}

/** `{required: [<bundle keys…>]}`. JSON Schema's `required` means "all of
 *  these", which is exactly the bundle-atomicity rule — for a bundle taken on
 *  its own. What it cannot express is that a *partial* bundle must fail; that
 *  stays SJON-side as `exclusive_bundle_partial`, and the
 *  `multi_key_exclusive_emitted` warning says so. */
function bundleRequired(bundle: readonly string[]): Record<string, unknown> {
  return { required: [...bundle] };
}

function buildExclusiveGroup(g: ModelExclusiveGroup): Record<string, unknown> {
  if (g.cardinality === 'exactly_one') {
    return { oneOf: g.alternatives.map(bundleRequired) };
  }
  // at-most-one. Two alternatives: "not both". More: "no pair of them", since
  // `not:{allOf:[a,b,c]}` would only forbid all three at once.
  if (g.alternatives.length === 2) {
    return { not: { allOf: g.alternatives.map(bundleRequired) } };
  }
  const pairs: Record<string, unknown>[] = [];
  for (let i = 0; i < g.alternatives.length; i++) {
    for (let j = i + 1; j < g.alternatives.length; j++) {
      pairs.push({
        allOf: [bundleRequired(g.alternatives[i]!), bundleRequired(g.alternatives[j]!)],
      });
    }
  }
  return { not: { anyOf: pairs } };
}

/** One `{if, then}` entry: when the discriminant is one of this variant's
 *  `:when` values, the variant's keys become known properties (and its
 *  required ones required). Each value is `{$sym: …}` because a discriminant
 *  is symbol-underlying by construction — `validateForms` rejects anything
 *  else before export runs. One value guards with `const`, several with
 *  `enum` — one branch either way, so a multi-value variant does not multiply
 *  the `allOf`. */
function buildVariantOverlay(
  discKey: string,
  variant: ModelVariant,
  ctx: EmitContext,
): Record<string, unknown> {
  const then: Record<string, unknown> = {};
  if (variant.keys.length > 0) {
    const properties: Record<string, unknown> = {};
    for (const k of [...variant.keys].sort((a, b) => a.name.localeCompare(b.name))) {
      properties[escapeFieldName(k.name)] = buildKey(k, ctx);
    }
    then['properties'] = properties;
    const required = variant.keys.filter((k) => !k.optional).map((k) => escapeFieldName(k.name));
    if (required.length > 0) then['required'] = required;
  }
  const gate =
    variant.when.length === 1
      ? { const: { $sym: variant.when[0]! } }
      : { enum: variant.when.map((w) => ({ $sym: w })) };
  return {
    if: {
      properties: { [discKey]: gate },
      required: [discKey],
    },
    then,
  };
}

function buildKey(key: ModelKey, ctx: EmitContext): Record<string, unknown> {
  const shape = buildShape(key.value, ctx);
  if (key.default) {
    // M1 attaches literal defaults as a JSON `default:` keyword on
    // the per-key schema. Expression defaults are recorded by the
    // lowering pass as a warning + annotation; no `default:` keyword.
    const def = serializeDefault(key.default);
    if (def !== undefined && isRecord(shape)) {
      shape['default'] = def;
    }
  }
  return shape as Record<string, unknown>;
}

function serializeDefault(def: NonNullable<ModelKey['default']>): unknown {
  switch (def.kind) {
    case 'nil':
      return null;
    case 'boolean':
      return def.value;
    case 'number':
      return def.value;
    case 'string':
      return def.value;
    case 'symbol':
      return { $sym: def.value };
    case 'vector':
      return def.elements.map(serializeDefault);
    case 'expression':
      return undefined; // dropped; expressed via warning + annotation
    default:
      return assertNever(def);
  }
}

/**
 * Per-head positional counts for a `$children` array: one `contains` +
 * `minContains` / `maxContains` per bounded head, gathered in an `allOf`
 * beside `items`.
 *
 * **Not** `minItems` / `maxItems` — those bound the array's *total*
 * length, a different claim: `:min 1 :max 1` on `vertex` says nothing
 * about how many `constant` children there are. `contains` counts the
 * elements matching one subschema, which is the per-head question.
 *
 * `minContains: 0` is emitted explicitly for a ceiling-only head:
 * without it, `contains` would additionally demand at least one match,
 * turning "at most one fragment" into "exactly one".
 *
 * Returns null when nothing is bounded, so an all-unbounded head-set
 * emits no `allOf` and stays byte-identical. Mirrors Zig's
 * `writeChildrenBounds`.
 */
/**
 * True when `shape` demands at least one positional child — i.e. some head
 * declares a `:min`. Separate from `isBoundedRef` because a ceiling-only
 * head-set is bounded but demands nothing. Mirrors Zig's
 * `shapeHasChildFloor`.
 */
function shapeHasChildFloor(shape: ModelValueShape): boolean {
  if (shape.kind !== 'form_heads') return false;
  return headSetHasFloor(shape);
}

function buildChildrenBounds(
  shape: ModelValueShape,
  ctx: EmitContext,
): readonly Record<string, unknown>[] | null {
  if (shape.kind !== 'form_heads') return null;
  if (!anyBoundedInSet(shape)) return null;
  const out: Record<string, unknown>[] = [];
  for (const head of shape.heads) {
    if (!isBoundedRef(head)) continue;
    const entry: Record<string, unknown> = {
      contains: headContains(head, ctx),
      minContains: head.min ?? 0,
    };
    if (head.max !== undefined) entry['maxContains'] = head.max;
    out.push(entry);
  }
  // The set's bound is one more entry in the same `allOf`, whose
  // `contains` is the `anyOf` of the members' — "a child whose head is in
  // the set", which is what the validator tallies. Mirrors Zig.
  if (isBoundedSet(shape)) {
    const entry: Record<string, unknown> = {
      contains: { anyOf: shape.heads.map((h) => headContains(h, ctx)) },
      minContains: shape.minChildren ?? 0,
    };
    if (shape.maxChildren !== undefined) entry['maxContains'] = shape.maxChildren;
    out.push(entry);
  }
  return out;
}

/**
 * The `contains` subschema for one head — a `$ref` for a global, a
 * head-pin otherwise. Shared by the per-head entries and the set's
 * `anyOf` so the two levels count children the same way; two spellings of
 * "a child carrying this head" would be a place for them to disagree.
 * Mirrors Zig's `writeHeadContains`.
 */
function headContains(head: ModelFormRef, ctx: EmitContext): Record<string, unknown> {
  if (refBody(head).kind !== 'global') return headPin(head.name);
  if (ctx.filterPlugin && head.plugin && head.plugin !== ctx.filterPlugin) {
    return { $ref: `./${head.plugin}.schema.json#/$defs/form.${head.plugin}.${head.name}` };
  }
  return { $ref: `#/$defs/form.${head.plugin || ''}.${head.name}` };
}

/**
 * `{type: object, properties: {$form: {const: <head>}}, required: [$form]}`
 * — "a form with this head, body unspecified". Two callers, both cases
 * where a head is accepted but has no schema to point at. Never a `$ref`:
 * an unresolvable one makes a 2020-12 validator reject the whole document
 * at compile time. Mirrors Zig's `writeHeadPin`.
 */
function headPin(head: string): Record<string, unknown> {
  return { type: 'object', properties: { $form: { const: head } }, required: ['$form'] };
}

function buildShape(shape: ModelValueShape, ctx: EmitContext): unknown {
  switch (shape.kind) {
    case 'any':
      return {};
    case 'nil':
      return { type: 'null' };
    case 'boolean':
      return { type: 'boolean' };
    case 'number':
      return { type: 'number' };
    case 'number_i64':
      return { type: 'integer', 'x-sjon-int-width': 'i64' };
    case 'number_u64':
      return { type: 'integer', 'x-sjon-int-width': 'u64' };
    case 'number_bounded':
      return buildNumberBounded(shape.bounds);
    case 'number_with_unit':
      return buildNumberWithUnit(shape.unit);
    case 'string':
      return { type: 'string' };
    case 'string_with_bounds':
      return buildStringWithBounds(shape.bounds);
    case 'symbol':
      return {
        type: 'object',
        required: ['$sym'],
        properties: { $sym: { type: 'string' } },
        additionalProperties: false,
      };
    case 'symbol_members':
      return { enum: shape.members.map((n) => ({ $sym: n })) };
    case 'symbol_members_rich':
      return { oneOf: shape.members.map((m) => buildRichMember(m, 'symbol')) };
    case 'string_members':
      return { enum: shape.members };
    case 'string_members_rich':
      return { oneOf: shape.members.map((m) => buildRichMember(m, 'string')) };
    case 'date':
      return {
        type: 'object',
        required: ['$date'],
        properties: {
          $date: { type: 'string', pattern: '^[0-9]{4}-[0-9]{2}-[0-9]{2}$', format: 'date' },
        },
        additionalProperties: false,
      };
    case 'time':
      return {
        type: 'object',
        required: ['$time'],
        properties: {
          $time: {
            type: 'string',
            pattern: '^[0-9]{2}:[0-9]{2}(:[0-9]{2}(\\.[0-9]{3})?)?$',
            format: 'time',
          },
        },
        additionalProperties: false,
      };
    case 'keyword':
      return {
        type: 'object',
        required: ['$kw'],
        properties: { $kw: { type: 'string', minLength: 1 } },
        additionalProperties: false,
      };
    case 'vector': {
      const out: Record<string, unknown> = { type: 'array' };
      if (shape.vector.element.kind !== 'any') {
        out['items'] = buildShape(shape.vector.element, ctx);
      }
      if (shape.vector.len != null) {
        out['minItems'] = shape.vector.len;
        out['maxItems'] = shape.vector.len;
      } else {
        // Variable arity: emit whichever bound is present.
        if (shape.vector.minLen != null) out['minItems'] = shape.vector.minLen;
        if (shape.vector.maxLen != null) out['maxItems'] = shape.vector.maxLen;
      }
      return out;
    }
    case 'form_any':
      return { type: 'object', required: ['$form'], properties: { $form: { type: 'string' } } };
    case 'form_heads': {
      // `oneOf` over one branch per accepted head — a `$ref` for a
      // global, the inline body for a slot-local, a head-pin for a head
      // nothing in scope resolves. No trailing open branch: a head-set
      // slot is closed (an out-of-set head is `not_head_member`).
      const refs = shape.heads.map((head) => {
        const body = refBody(head);
        if (body.kind === 'local') {
          return buildForm(
            ctx.plugin ?? { name: '', version: '', description: '', forms: [], valueKinds: [] },
            body.form,
            ctx,
          );
        }
        if (body.kind === 'unresolved') return headPin(head.name);
        if (ctx.filterPlugin && head.plugin && head.plugin !== ctx.filterPlugin) {
          return { $ref: `./${head.plugin}.schema.json#/$defs/form.${head.plugin}.${head.name}` };
        }
        return { $ref: `#/$defs/form.${head.plugin || ''}.${head.name}` };
      });
      const out: Record<string, unknown> = {
        oneOf: refs,
        'x-sjon-head-set': shape.heads.map((h) => h.name),
      };
      const locals = shape.heads.filter((h) => refBody(h).kind === 'local').map((h) => h.name);
      if (locals.length > 0) out['x-sjon-local-forms'] = locals;
      return out;
    }
    case 'form_locals': {
      // Inline anonymous union: one full object schema per local form
      // (reusing `buildForm`, so a discriminated local keeps its if/then —
      // bodies inline, NOT `$ref`s, since locals have no global `$def`), plus
      // a trailing open generic branch for the additive global fallback.
      // `anyOf`, not `oneOf`: the open branch overlaps every specific branch,
      // so exactly-one would always fail (same reason `union_of` uses anyOf).
      const branches: unknown[] = shape.forms.map((lf) =>
        buildForm(
          ctx.plugin ?? { name: '', version: '', description: '', forms: [], valueKinds: [] },
          lf,
          ctx,
        ),
      );
      branches.push({ type: 'object', required: ['$form'] });
      return { anyOf: branches, 'x-sjon-local-forms': shape.forms.map((lf) => lf.name) };
    }
    case 'expr':
      return {
        type: 'object',
        required: ['$expr'],
        properties: { $expr: { type: 'array' } },
      };
    case 'cross_ref': {
      // Optional members are omitted, not spelled `null` — the Zig emitter's
      // rule (`JsonSchema.zig`), which this port used to break for
      // `scope-form` alone. `name-key` / `acyclic` stay unconditional on
      // both routes, so the annotation keeps a stable field set.
      // One target keeps `target-form`, byte-identically; a group gets
      // `target-forms`, an array — following `scope-form`'s
      // omit-when-inapplicable rule, so a consumer that only understands
      // the singular key finds it *absent* on a group rather than reading a
      // group as a single target it cannot represent.
      const anno: Record<string, unknown> =
        shape.crossRef.targets.length === 1
          ? {
              'target-form': shape.crossRef.targets[0]!,
              'name-key': shape.crossRef.nameKey,
              acyclic: shape.crossRef.acyclic,
            }
          : {
              'target-forms': [...shape.crossRef.targets],
              'name-key': shape.crossRef.nameKey,
              acyclic: shape.crossRef.acyclic,
            };
      if (shape.crossRef.scopeForm !== null) anno['scope-form'] = shape.crossRef.scopeForm;
      if (shape.crossRef.provider !== null) anno['provider'] = shape.crossRef.provider;
      if (shape.crossRef.sourceKey !== null) anno['source-key'] = shape.crossRef.sourceKey;
      return {
        type: 'object',
        required: ['$sym'],
        properties: { $sym: { type: 'string' } },
        additionalProperties: false,
        'x-sjon-cross-ref': anno,
      };
    }
    case 'union_of':
      return {
        anyOf: shape.alternatives.map((alt) => buildShape(alt.shape, ctx)),
        'x-sjon-union-alternatives': shape.alternatives.map((alt) => alt.name),
      };
    case 'unresolved_named': {
      const display = shape.namespace ? `${shape.namespace}/${shape.name}` : shape.name;
      return { 'x-sjon-unresolved-named': display };
    }
    default:
      return assertNever(shape);
  }
}

function buildNumberBounded(b: ModelNumericBounds): Record<string, unknown> {
  const out: Record<string, unknown> = b.integer ? { type: 'integer' } : { type: 'number' };
  applyBound(out, b);
  return out;
}

function applyBound(target: Record<string, unknown>, b: ModelNumericBounds) {
  if (b.min) {
    if (b.exclusiveMin) target['exclusiveMinimum'] = b.min.value;
    else target['minimum'] = b.min.value;
  }
  if (b.max) {
    if (b.exclusiveMax) target['exclusiveMaximum'] = b.max.value;
    else target['maximum'] = b.max.value;
  }
  // Exact semantic match rather than an annotation: 2020-12's `multipleOf`
  // is "division by this keyword's value results in an integer", which is
  // the claim `:multiple-of` makes.
  if (b.multipleOf) target['multipleOf'] = b.multipleOf.value;
  if ((b.min && b.min.exactIntDigits) || (b.max && b.max.exactIntDigits)) {
    const annotation: Record<string, string> = {};
    if (b.min?.exactIntDigits) annotation['min'] = b.min.exactIntDigits;
    if (b.max?.exactIntDigits) annotation['max'] = b.max.exactIntDigits;
    target['x-sjon-exact-bound'] = annotation;
  }
  // GPU representation tag. Annotation-only — generic validators ignore it.
  // Shared by buildNumberBounded and the unit magnitude (parity with the
  // Zig writeNumericBoundsBody reuse).
  if (b.repr) target['x-sjon-gpu-repr'] = b.repr;
}

function buildNumberWithUnit(u: ModelUnitShape): Record<string, unknown> {
  const magnitude: Record<string, unknown> = { type: 'number' };
  if (u.bounds) applyBound(magnitude, u.bounds);
  const unitSchema: Record<string, unknown> =
    u.allowed.length > 0
      ? { type: 'string', enum: [...u.allowed] }
      : { type: 'string', minLength: 1 };
  return {
    type: 'object',
    required: ['$num'],
    additionalProperties: false,
    properties: {
      $num: {
        type: 'array',
        prefixItems: [magnitude, unitSchema],
        minItems: 2,
        maxItems: 2,
        items: false,
      },
    },
  };
}

function buildStringWithBounds(b: ModelStringBounds): Record<string, unknown> {
  const out: Record<string, unknown> = { type: 'string' };
  if (b.minLen != null) out['minLength'] = b.minLen;
  if (b.maxLen != null) out['maxLength'] = b.maxLen;
  if (b.pattern != null) {
    out['pattern'] = b.pattern;
    out['x-sjon-pattern-engine'] = 'deferred-in-sjon-runtime';
  }
  if (b.format) {
    if (b.format === 'email' || b.format === 'uri' || b.format === 'uuid') {
      out['format'] = b.format;
    } else {
      out['x-sjon-format'] = b.format;
    }
  }
  return out;
}

/// A digit-leading member is the exception on both underlyings: a document
/// writes it as a unit-bearing number, so the JSON bridge encodes it as
/// `{"$num": [magnitude, unit]}` and that is what gets pinned. A `$sym`
/// const there would reject a document the validator accepts.
function buildRichMember(m: ModelMember, underlying: 'symbol' | 'string'): Record<string, unknown> {
  const out: Record<string, unknown> = {
    const:
      m.numericSpelling !== undefined
        ? { $num: [m.numericSpelling.magnitude, m.numericSpelling.unit] }
        : underlying === 'symbol'
          ? { $sym: m.name }
          : m.name,
  };
  if (m.label) out['title'] = m.label;
  if (m.description) out['description'] = m.description;
  if (m.deprecated) out['deprecated'] = true;
  if (m.deprecationMessage) out['x-sjon-deprecation-message'] = m.deprecationMessage;
  return out;
}

/**
 * Escape declared `$`-prefixed user keys per `Json.zig`'s
 * canonical-mode rule: doubled `$` → `$$`. Plain keys pass through.
 */
function escapeFieldName(name: string): string {
  if (name.startsWith('$')) return '$' + name;
  return name;
}

// Touch unused imports to satisfy strict TS — some types are exported
// from `../plugin.ts` for downstream consumers but aren't referenced
// here directly.
void (null as unknown as Member);
