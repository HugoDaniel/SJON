// Schema → Model lowering — TypeScript port of
// `src/SchemaExport/SchemaExport.zig`'s lowering pass.
//
// Walks the TS-parity Schema (forms + value-kinds) and produces a
// classified Model the backends consume mechanically. Named-kind
// references resolve one hop deep via `lookupValueKind`; refinement
// axes (vector / unit / numeric / string-bounds / cross-ref /
// members / heads) classify into their own `ModelValueShape` branch.
//
// Coverage parity note: union-of alternatives resolve here (via the
// scalar-or-ref desugar, `union [<base> symbol]`) — `lowerValueKind` maps
// each alternative through `resolveNamedShape`, matching the Zig exporter —
// and so, now that `loader.ts` parses them, do the discriminator + its
// variants and the exclusive groups. `lowering` is the one M2 field still
// pinned null: it declares a host-owned hook this declarative-only port has
// no registry for, so there is nothing to carry through.

import type {
  Plugin,
  Schema,
  FormSpec,
  KeyDefault,
  KeySpec,
  ValueKind,
  ValueType,
  NumericBounds,
  NumericBound,
  StringBounds,
} from '../plugin.ts';
import { effectiveOptional, lookupForm, lookupValueKind } from '../plugin.ts';
import type {
  Model,
  ModelDefault,
  ModelDiscriminator,
  ModelExclusiveGroup,
  ModelForm,
  ModelKey,
  ModelMember,
  ModelNumericBound,
  ModelNumericBounds,
  ModelPlugin,
  ModelPositional,
  ModelStringBounds,
  ModelUnionAlternative,
  ModelValueKindEntry,
  ModelValueShape,
} from './model.ts';
import { makeWarning, type Warning } from './warnings.ts';
import { assertNever } from '../internal.ts';

const F64_PRECISE_INT_CEILING = 2 ** 53;

interface LowerCtx {
  schema: Schema;
  warnings: Warning[];
}

/** Entry point — lower a Schema to the IR. */
export function lowerSchema(schema: Schema): { model: Model; warnings: readonly Warning[] } {
  const ctx: LowerCtx = { schema, warnings: [] };
  const plugins: ModelPlugin[] = schema.plugins.map((p) => lowerPlugin(ctx, p));
  return {
    model: { plugins, version: 1 },
    warnings: dedupeWarnings(ctx.warnings),
  };
}

function lowerPlugin(ctx: LowerCtx, plugin: Plugin): ModelPlugin {
  const forms: ModelForm[] = plugin.forms.map((f) => lowerForm(ctx, plugin, f));
  const valueKinds: ModelValueKindEntry[] = plugin.valueKinds.map((vk) => ({
    name: vk.name,
    description: '',
    shape: lowerValueKind(ctx, plugin, vk),
    originPlugin: plugin.name,
  }));
  return {
    name: plugin.name,
    version: plugin.version,
    description: '',
    forms,
    valueKinds,
  };
}

function lowerForm(ctx: LowerCtx, plugin: Plugin, form: FormSpec): ModelForm {
  const keys: ModelKey[] = form.keys.map((k) => lowerKey(ctx, plugin, form, k));
  let positional: ModelPositional;
  switch (form.positional.kind) {
    case 'none':
      positional = { kind: 'none' };
      break;
    case 'any':
      positional = { kind: 'any' };
      break;
    case 'kind':
      positional = {
        kind: 'kind',
        shape: resolveNamedShape(ctx, plugin, form.positional.name, form.positional.namespace, {
          pluginName: plugin.name,
          formName: form.name,
        }),
      };
      break;
    case 'flag_set':
      // Positional keyword flags don't constrain a child value shape, so
      // widen to `any`; the names + metadata ride alongside as the
      // `x-sjon-positional-flags` annotation (see positionalFlags below).
      positional = { kind: 'any' };
      break;
    default:
      assertNever(form.positional);
  }

  // Positional slot-local forms override the positional child shape to the
  // same inline anonymous union (`form_locals`) `lowerKey` uses for keyed
  // locals — each local lowered via `lowerForm` (a discriminated local keeps
  // its if/then). Rides independent of the declared positional variant
  // (`any` / head-set `kind`); the head-set gate stays SJON-only. Reuses the
  // `local_forms_emitted_inline` warning (form-scoped, no key). Mirrors the
  // Zig `lowerForm` hook.
  if (form.localForms && form.localForms.length > 0) {
    positional = {
      kind: 'kind',
      shape: {
        kind: 'form_locals',
        forms: form.localForms.map((lf) => lowerForm(ctx, plugin, lf)),
      },
    };
    ctx.warnings.push(
      makeWarning(
        'local_forms_emitted_inline',
        'info',
        `positional slot on form \`${form.name}\` declares ${form.localForms.length} local form(s) — emitted as an inline union plus an open generic branch for the additive global fallback; local-first/global resolution order is SJON-only`,
        { pluginName: plugin.name, formName: form.name },
      ),
    );
  }

  const positionalFlags =
    form.positional.kind === 'flag_set'
      ? form.positional.flags.map((f) => {
          const out: { name: string; description?: string; link?: string } = { name: f.name };
          if (f.description !== undefined) out.description = f.description;
          if (f.link !== undefined) out.link = f.link;
          return out;
        })
      : undefined;
  // Discriminator snapshot. The backends turn this into allOf+if/then; the
  // variant keys lower exactly like common keys, so a variant slot keeps its
  // resolved shape rather than degrading to `any`.
  let discriminator: ModelDiscriminator | null = null;
  const didx = form.discriminantIdx;
  if (didx !== undefined && didx < form.keys.length) {
    discriminator = {
      keyName: form.keys[didx]!.name,
      variants: (form.variants ?? []).map((v) => ({
        when: v.when,
        keys: v.keys.map((k) => lowerKey(ctx, plugin, form, k)),
      })),
    };
    ctx.warnings.push(
      makeWarning(
        'variants_emitted_via_if_then',
        'info',
        `discriminated form \`${form.name}\` — variants emitted as allOf+if/then; source-order (variant keys must follow the discriminant) is not enforced by JSON Schema`,
        { pluginName: plugin.name, formName: form.name },
      ),
    );
  }

  const sourceGroups = form.exclusiveGroups ?? [];
  const exclusiveGroups: ModelExclusiveGroup[] = sourceGroups.map((g) => ({
    cardinality: g.cardinality,
    alternatives: g.alternatives.map((alt) => alt.keys),
  }));
  if (sourceGroups.length > 0) {
    ctx.warnings.push(
      makeWarning(
        'exclusive_group_unenforceable',
        'info',
        `form \`${form.name}\` exclusive groups emitted structurally (\`oneOf\` for exactly_one, \`not:{allOf}\` for at_most_one); source-order constraints between variant keys and discriminants remain SJON-only`,
        { pluginName: plugin.name, formName: form.name },
      ),
    );
    // Bundle atomicity is the part JSON Schema cannot express: `required`
    // per bundle admits a partial bundle whenever a sibling alt is also
    // satisfiable, which is precisely what `exclusive_bundle_partial`
    // catches at SJON validate time.
    if (sourceGroups.some((g) => g.alternatives.some((alt) => alt.keys.length > 1))) {
      ctx.warnings.push(
        makeWarning(
          'multi_key_exclusive_emitted',
          'info',
          `form \`${form.name}\` has at least one multi-key bundle in an exclusive group; emitted as \`{required: [<bundle>]}\` per bundle. Bundle atomicity (partial bundles fail) requires SJON-aware runtime validation`,
          { pluginName: plugin.name, formName: form.name },
        ),
      );
    }
  }

  return {
    name: form.name,
    description: '',
    keys,
    positional,
    open: form.open,
    discriminator,
    exclusiveGroups,
    // A `:lowering` declaration names a host-owned hook; this port has no
    // hook registry, and its loader does not parse the declaration.
    lowering: null,
    ...(positionalFlags !== undefined ? { positionalFlags } : {}),
  };
}

function lowerKey(ctx: LowerCtx, plugin: Plugin, form: FormSpec, key: KeySpec): ModelKey {
  let value = lowerValueType(ctx, plugin, key.valueType, {
    pluginName: plugin.name,
    formName: form.name,
    keyName: key.name,
  });

  // Slot-local forms live on the key, not the type: a `:type form` slot
  // (lowered to form_any above) carrying inline locals is re-shaped to an
  // inline anonymous union (form_locals). Each local lowers via lowerForm so
  // a discriminated local keeps its if/then; recursion is bounded by the
  // finite manifest tree. Mirrors the Zig `lowerKey` hook.
  if (key.localForms && key.localForms.length > 0) {
    value = { kind: 'form_locals', forms: key.localForms.map((lf) => lowerForm(ctx, plugin, lf)) };
    ctx.warnings.push(
      makeWarning(
        'local_forms_emitted_inline',
        'info',
        `slot \`:${key.name}\` on form \`${form.name}\` declares ${key.localForms.length} local form(s) — emitted as an inline union plus an open generic branch for the additive global fallback; local-first/global resolution order is SJON-only`,
        { pluginName: plugin.name, formName: form.name, keyName: key.name },
      ),
    );
  }

  return {
    name: key.name,
    // The exported `.d.ts` is the authoring shape: a defaulted key is
    // optional (may be omitted). Mirrors the Zig exporter's
    // `key.effectiveOptional()` so the two hosts agree.
    optional: effectiveOptional(key),
    description: '',
    value,
    default: lowerKeyDefault(key.default),
    requires: key.requires ?? [],
  };
}

/** Lower a parsed `KeyDefault` to the exporter `ModelDefault` (1:1; mirrors Zig `lowerDefault`). */
function lowerKeyDefault(d: KeyDefault | null | undefined): ModelDefault | null {
  if (d == null) return null;
  switch (d.kind) {
    case 'nil':
      return { kind: 'nil' };
    case 'boolean':
      return { kind: 'boolean', value: d.value };
    case 'number':
      return { kind: 'number', value: d.value };
    case 'string':
      return { kind: 'string', value: d.value };
    case 'symbol':
      return { kind: 'symbol', value: d.value };
    case 'vector':
      // Elements are always representable (a non-representable element voids
      // the whole vector at parse time), so the recursion never yields null.
      return { kind: 'vector', elements: d.elements.map((e) => lowerKeyDefault(e)!) };
    case 'expression':
      return {
        kind: 'expression',
        snapshot: { head: d.head, namespace: d.namespace, argCount: d.argCount },
      };
    default:
      return assertNever(d);
  }
}

function lowerValueKind(ctx: LowerCtx, plugin: Plugin, vk: ValueKind): ModelValueShape {
  // Refinement axes layered onto the underlying type. Order matters —
  // unit-with-numeric pulls bounds into the unit shape; numeric-only
  // routes through number_bounded; etc.
  const scope = { pluginName: plugin.name, kindName: vk.name };
  // union_of replaces the underlying mapping entirely, so it resolves
  // first — and a union_of kind (today only produced by the scalar-or-ref
  // desugar, `union [<base> symbol]`) never carries the unit/numeric/
  // string/etc. axes, so precedence is moot for valid input and matches
  // the Zig exporter's ordering (union handled before the underlying
  // switch — SchemaExport.zig `if (vk.union_of)`). Each alternative is a
  // name reference resolved through the same recursive `resolveNamedShape`
  // the key/vector/positional slots use.
  if (vk.unionOf) {
    ctx.warnings.push(
      makeWarning(
        'union_emitted_via_anyof',
        'info',
        `value-kind \`${vk.name}\` union_of emitted as JSON Schema \`anyOf\` over resolved ` +
          `alternatives; SJON's first-match dispatch order is preserved in ` +
          `\`x-sjon-union-alternatives\``,
        scope,
      ),
    );
    const alternatives: ModelUnionAlternative[] = vk.unionOf.alternatives.map((alt) => ({
      name: alt.name,
      shape: resolveNamedShape(ctx, plugin, alt.name, alt.namespace, scope),
    }));
    return { kind: 'union_of', alternatives };
  }
  // A `:reject` unit-shape demands bare numbers (units forbidden), so it
  // exports as a plain number / bounded-number — never number_with_unit.
  // Parity with the Zig exporter's lowerNumberKind gate.
  if (vk.unit && !vk.unit.reject) {
    // The repr (if any) rides in the unit's bounds for the JSON Schema
    // `x-sjon-gpu-repr` annotation; the TS tuple stays plain (parity with
    // the Zig exporter's unit+repr corner).
    let bounds = vk.numeric ? lowerNumericBounds(ctx, vk.numeric, scope) : null;
    if (vk.repr) bounds = { ...(bounds ?? emptyNumericBounds()), repr: vk.repr };
    ctx.warnings.push(
      makeWarning(
        'number_with_unit_emitted_via_prefix_items',
        'info',
        `value-kind \`${vk.name}\` — number-with-unit emitted via \`prefixItems: [<magnitude>, <unit>]\``,
        scope,
      ),
    );
    return {
      kind: 'number_with_unit',
      unit: {
        required: vk.unit.required,
        allowed: vk.unit.allowed,
        bounds,
      },
    };
  }
  // Merge `:numeric` and `:repr` — either may be present independently. A
  // repr-only kind yields number_bounded with null min/max + repr. Parity
  // with the Zig exporter's lowerNumberKind.
  if (vk.numeric || vk.repr) {
    const base = vk.numeric ? lowerNumericBounds(ctx, vk.numeric, scope) : emptyNumericBounds();
    const bounds: ModelNumericBounds = vk.repr ? { ...base, repr: vk.repr } : base;
    // The min/max warning only fires when `:numeric` supplied real bounds;
    // a repr-only kind emits just the annotation, no range keywords.
    if (vk.numeric) {
      ctx.warnings.push(
        makeWarning(
          'numeric_bounds_emitted_via_min_max',
          'info',
          `value-kind \`${vk.name}\` — numeric bounds emitted via \`minimum\`/\`maximum\`${
            bounds.integer ? ' + `type: integer`' : ''
          }`,
          scope,
        ),
      );
    }
    return { kind: 'number_bounded', bounds };
  }
  if (vk.stringBounds) {
    ctx.warnings.push(
      makeWarning(
        'string_bounds_emitted_via_keywords',
        'info',
        `value-kind \`${vk.name}\` — string bounds emitted via \`minLength\`/\`maxLength\`/\`pattern\`/\`format\``,
        scope,
      ),
    );
    return {
      kind: 'string_with_bounds',
      bounds: lowerStringBounds(vk.stringBounds),
    };
  }
  if (vk.crossRef) {
    // Three warnings, matching `lowerValueKind` in
    // `src/SchemaExport/SchemaExport.zig` message-for-message. This port
    // used to push only the `info` one, leaving the `cross_ref_unenforceable`
    // its own `WarningCode` union declares unreachable — a consumer diffing
    // the two exporters' warning sets saw a difference that was an omission,
    // not a decision.
    const provider = vk.crossRef.provider ?? null;
    const sourceKey = provider === null ? null : (vk.crossRef.sourceKey ?? 'src');
    const nameKey = vk.crossRef.nameKey ?? 'name';
    const acyclic = vk.crossRef.acyclic ?? false;
    const scopeForm = vk.crossRef.scopeForm ?? null;
    ctx.warnings.push(
      makeWarning(
        'cross_ref_unenforceable',
        'warn',
        provider === null
          ? `value-kind \`${vk.name}\` cross-ref: schema validates symbol shape only; closed-set membership requires SJON-aware validator`
          : `value-kind \`${vk.name}\` cross-ref: schema validates symbol shape only; the member set is extracted from each target's \`:${sourceKey}\` string by provider \`${provider}\` during validation, so it is not knowable at export time`,
        scope,
      ),
    );
    ctx.warnings.push(
      makeWarning(
        'cross_ref_annotation_only',
        'info',
        provider === null
          ? `value-kind \`${vk.name}\` cross-ref annotation surfaces target-form=\`${vk.crossRef.targets.join(' | ')}\` name-key=\`${nameKey}\` acyclic=${acyclic} scope-form=\`${scopeForm ?? ''}\`; none are enforceable by JSON Schema`
          : `value-kind \`${vk.name}\` cross-ref annotation surfaces target-form=\`${vk.crossRef.targets.join(' | ')}\` provider=\`${provider}\` source-key=\`${sourceKey}\` scope-form=\`${scopeForm ?? ''}\`; none are enforceable by JSON Schema`,
        scope,
      ),
    );
    if (acyclic) {
      ctx.warnings.push(
        makeWarning(
          'acyclic_unenforceable',
          'warn',
          `value-kind \`${vk.name}\` declares \`:acyclic true\`; cycle detection cannot be enforced by JSON Schema`,
          scope,
        ),
      );
    }
    return {
      kind: 'cross_ref',
      crossRef: {
        targets: vk.crossRef.targets,
        nameKey,
        acyclic,
        scopeForm,
        provider,
        sourceKey,
      },
    };
  }
  if (vk.heads && vk.heads.length > 0) {
    const heads = vk.heads.map((entry) => {
      const hit = lookupForm(ctx.schema, entry.name, null);
      const owner =
        hit.kind === 'found' ? (findOwningPlugin(ctx.schema, hit.value) ?? plugin.name) : '';
      const ref: { plugin: string; name: string; min?: number; max?: number } = {
        plugin: owner,
        name: entry.name,
      };
      if (entry.min !== undefined) ref.min = entry.min;
      if (entry.max !== undefined) ref.max = entry.max;
      return ref;
    });
    ctx.warnings.push(
      makeWarning(
        'head_set_emitted_via_oneof_refs',
        'info',
        `value-kind \`${vk.name}\` — head-set emitted as \`oneOf\` of \`$ref\`s into \`#/$defs/form.<plugin>.<head>\``,
        scope,
      ),
    );
    return { kind: 'form_heads', heads };
  }
  if (vk.members && vk.members.length > 0) {
    const isAnnotated = vk.members.some(
      (m) => m.label || m.description || m.deprecated || m.deprecationMessage,
    );
    // A digit-leading spelling forces the rich shape whether or not it
    // carries annotations: it is written as a unit-bearing number, so the
    // compact `enum` of `$sym` entries cannot express it and would reject
    // a document the validator accepts.
    const isNumeric = vk.members.some((m) => m.numericSpelling !== undefined);
    if (isAnnotated || isNumeric) {
      ctx.warnings.push(
        makeWarning(
          'rich_members_emitted_with_annotations',
          'info',
          isNumeric && isAnnotated
            ? `value-kind \`${vk.name}\` — rich member-set emitted as \`oneOf\` of \`const\`-pinned objects with title/description/deprecated annotations and \`$num\` wire shapes`
            : isNumeric
              ? `value-kind \`${vk.name}\` — member-set carries digit-leading spellings; emitted as \`oneOf\`, with each digit-leading member pinned to its \`$num\` wire shape rather than \`$sym\``
              : `value-kind \`${vk.name}\` — rich member-set emitted as \`oneOf\` of \`const\`-pinned objects with title/description/deprecated annotations`,
          scope,
        ),
      );
      const members: ModelMember[] = vk.members.map((m) => ({
        name: m.name,
        label: m.label ?? '',
        description: m.description ?? '',
        deprecated: m.deprecated ?? false,
        deprecationMessage: m.deprecationMessage ?? '',
        ...(m.numericSpelling !== undefined
          ? {
              numericSpelling: { magnitude: m.numericSpelling.value, unit: m.numericSpelling.unit },
            }
          : {}),
      }));
      return vk.underlying === 'string'
        ? { kind: 'string_members_rich', members }
        : { kind: 'symbol_members_rich', members };
    }
    const names = vk.members.map((m) => m.name);
    return vk.underlying === 'string'
      ? { kind: 'string_members', members: names }
      : { kind: 'symbol_members', members: names };
  }
  if (vk.vector) {
    return {
      kind: 'vector',
      vector: {
        len: vk.vector.len ?? null,
        minLen: vk.vector.minLen ?? null,
        maxLen: vk.vector.maxLen ?? null,
        element: lowerValueType(
          ctx,
          plugin,
          { kind: 'named', name: vk.vector.element.name, namespace: vk.vector.element.namespace },
          scope,
        ),
      },
    };
  }
  // Bare underlying without any refinement axis.
  return lowerUnderlying(vk.underlying);
}

function lowerUnderlying(underlying: ValueKind['underlying']): ModelValueShape {
  switch (underlying) {
    case 'number':
      return { kind: 'number' };
    case 'string':
      return { kind: 'string' };
    case 'symbol':
      return { kind: 'symbol' };
    case 'vector':
      return {
        kind: 'vector',
        vector: { len: null, minLen: null, maxLen: null, element: { kind: 'any' } },
      };
    case 'form':
      return { kind: 'form_any' };
    case 'union_of':
      // Degenerate fallback only: `underlying: 'union_of'` with no
      // `unionOf` alternatives field (the loader never produces this).
      // The populated path lives in `lowerValueKind`'s `vk.unionOf`
      // branch, which resolves each alternative via `resolveNamedShape`.
      // Emit an empty anyOf so the artifact stays well-formed. (Zig makes
      // this case `unreachable`; the TS switch stays total instead.)
      return { kind: 'union_of', alternatives: [] };
    default:
      return assertNever(underlying);
  }
}

function lowerValueType(
  ctx: LowerCtx,
  plugin: Plugin,
  vt: ValueType,
  scope: { pluginName?: string; formName?: string; keyName?: string; kindName?: string },
): ModelValueShape {
  switch (vt.kind) {
    case 'any':
      return { kind: 'any' };
    case 'number':
      return { kind: 'number' };
    case 'string':
      return { kind: 'string' };
    case 'symbol':
      return { kind: 'symbol' };
    case 'boolean':
      return { kind: 'boolean' };
    case 'nil':
      return { kind: 'nil' };
    case 'vector':
      return {
        kind: 'vector',
        vector: { len: null, minLen: null, maxLen: null, element: { kind: 'any' } },
      };
    case 'form':
      return { kind: 'form_any' };
    case 'expr':
      ctx.warnings.push(
        makeWarning(
          'expression_slot_annotation_only',
          'warn',
          'expression slot — runtime type unverifiable by JSON Schema',
          scope,
        ),
      );
      return { kind: 'expr' };
    case 'named':
      return resolveNamedShape(ctx, plugin, vt.name, vt.namespace, scope);
    default:
      return assertNever(vt);
  }
}

function resolveNamedShape(
  ctx: LowerCtx,
  plugin: Plugin,
  name: string,
  namespace: string | null,
  scope: { pluginName?: string; formName?: string; keyName?: string; kindName?: string },
): ModelValueShape {
  // Primitive-name shortcut — the TS plugin model lets keys reference
  // `number` / `string` / etc. via `{kind: 'named', name: 'number'}`.
  const primitive = primitiveShortcut(name);
  if (primitive) return primitive;

  const hit = lookupValueKind(ctx.schema, name, namespace);
  if (hit.kind === 'found') {
    return lowerValueKind(ctx, plugin, hit.value);
  }
  // Could also be a form name (form-as-slot shape).
  const formHit = lookupForm(ctx.schema, name, namespace);
  if (formHit.kind === 'found') {
    const owner = findOwningPlugin(ctx.schema, formHit.value) ?? plugin.name;
    return { kind: 'form_heads', heads: [{ plugin: owner, name }] };
  }
  const display = namespace ? `${namespace}/${name}` : name;
  ctx.warnings.push(
    makeWarning('deferred_construct', 'warn', `unresolved named type \`${display}\``, scope),
  );
  return { kind: 'unresolved_named', name, namespace };
}

function primitiveShortcut(name: string): ModelValueShape | null {
  switch (name) {
    case 'any':
      return { kind: 'any' };
    case 'nil':
      return { kind: 'nil' };
    case 'boolean':
      return { kind: 'boolean' };
    case 'number':
      return { kind: 'number' };
    case 'string':
      return { kind: 'string' };
    case 'symbol':
      return { kind: 'symbol' };
    case 'keyword':
      return { kind: 'keyword' };
    case 'date':
      return { kind: 'date' };
    case 'time':
      return { kind: 'time' };
    case 'form':
      return { kind: 'form_any' };
    case 'expr':
      return { kind: 'expr' };
    default:
      return null;
  }
}

function lowerNumericBounds(
  ctx: LowerCtx,
  src: NumericBounds,
  scope: { pluginName?: string; formName?: string; kindName?: string; keyName?: string },
): ModelNumericBounds {
  const min = src.min ? lowerBound(ctx, src.min, scope) : null;
  const max = src.max ? lowerBound(ctx, src.max, scope) : null;
  return {
    min,
    max,
    exclusiveMin: src.exclusiveMin,
    exclusiveMax: src.exclusiveMax,
    integer: src.integer,
    multipleOf: src.multipleOf ? lowerBound(ctx, src.multipleOf, scope) : null,
    // `:repr` is merged in by the caller (lowerValueKind) — `:numeric` and
    // `:repr` are orthogonal axes that both land on ModelNumericBounds.
    repr: null,
  };
}

// A bounds object with no range/integrality constraints, for a repr-only
// kind (`:repr` with no `:numeric`). The caller spreads `repr` over it.
function emptyNumericBounds(): ModelNumericBounds {
  return {
    min: null,
    max: null,
    exclusiveMin: false,
    exclusiveMax: false,
    integer: false,
    multipleOf: null,
    repr: null,
  };
}

function lowerBound(
  ctx: LowerCtx,
  src: NumericBound,
  scope: { pluginName?: string; formName?: string; kindName?: string; keyName?: string },
): ModelNumericBound {
  let exactIntDigits: string | null = null;
  if (src.exactInt && Math.abs(src.value) > F64_PRECISE_INT_CEILING) {
    exactIntDigits = src.integerBits != null ? src.integerBits.toString() : String(src.value);
    ctx.warnings.push(
      makeWarning(
        'numeric_bound_exceeds_double_range',
        'info',
        `numeric bound exceeds 2^53 — emitted as \`x-sjon-exact-bound\` digit string for precision recovery`,
        scope,
      ),
    );
  }
  return {
    value: src.value,
    unit: src.unit ?? null,
    exactInt: src.exactInt,
    exactIntDigits,
  };
}

function lowerStringBounds(src: StringBounds): ModelStringBounds {
  return {
    minLen: src.minLen ?? null,
    maxLen: src.maxLen ?? null,
    pattern: src.pattern ?? null,
    format: src.format ?? null,
  };
}

function findOwningPlugin(schema: Schema, form: FormSpec): string | null {
  for (const p of schema.plugins) {
    for (const f of p.forms) {
      if (f === form) return p.name;
    }
  }
  return null;
}

// Useful when a key/kind/form referenced the same kind twice; the
// downstream warning surface should not balloon.
function dedupeWarnings(input: readonly Warning[]): Warning[] {
  const out: Warning[] = [];
  outer: for (const w of input) {
    for (const existing of out) {
      if (existing.code !== w.code) continue;
      if (existing.message !== w.message) continue;
      if ((existing.pluginName ?? null) !== (w.pluginName ?? null)) continue;
      if ((existing.formName ?? null) !== (w.formName ?? null)) continue;
      if ((existing.keyName ?? null) !== (w.keyName ?? null)) continue;
      if ((existing.kindName ?? null) !== (w.kindName ?? null)) continue;
      continue outer;
    }
    out.push(w);
  }
  return out;
}

// Re-export the deduplicator so the entry point in `index.ts` can
// dedupe after merging lowering + emit warnings.
export { dedupeWarnings };
