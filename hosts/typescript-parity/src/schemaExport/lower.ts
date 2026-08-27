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
  ModelFormRef,
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

/**
 * The slot-local form registry in scope for a head-set resolution, in
 * both source and lowered form (index-parallel — a `local` head embeds
 * the lowered body, so `lowerForm` lowers its locals before resolving
 * the positional kind). Mirrors `Context.locals` / `lowered_locals` in
 * `src/SchemaExport/SchemaExport.zig`.
 */
interface SlotLocals {
  readonly specs: readonly FormSpec[];
  readonly lowered: readonly ModelForm[];
}

/**
 * Where a value-kind is being lowered *from*: the names that scope a
 * warning, plus the slot.
 *
 * An absent `slot` means there is **no slot** — `lowerPlugin`'s
 * standalone pass over every value-kind, which exists for the Markdown
 * and IR channels. Absent-versus-empty is load-bearing: "this slot
 * declares no locals" is a verdict a head-set resolution can act on, and
 * "there is no slot" is the absence of one. Only the first may call a
 * head unresolvable.
 */
interface LowerScope {
  readonly pluginName?: string;
  readonly formName?: string;
  readonly keyName?: string;
  readonly kindName?: string;
  readonly slot?: SlotLocals;
}

/**
 * A slot that declares no locals — distinct from no slot at all. Used by
 * the two sites that are structurally locals-free: a keyed slot (the
 * loader rejects keyed locals on anything but `:type form`, so a keyed
 * slot can never carry both a head-set and locals) and a vector element
 * (a value, not a form child, so no registry ever reaches one).
 */
const NO_LOCALS: SlotLocals = { specs: [], lowered: [] };

/** True when a slot is in hand, so the head-set resolution is complete. */
function scopeJudges(scope: LowerScope): boolean {
  return scope.slot !== undefined;
}

/** The lowered body of the slot-local matching `head`, or null. */
function matchSlotLocal(scope: LowerScope, head: string): ModelForm | null {
  const slot = scope.slot;
  if (!slot) return null;
  for (let i = 0; i < slot.specs.length; i += 1) {
    if (slot.specs[i]!.name === head) return slot.lowered[i]!;
  }
  return null;
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
    // No slot: this pass exists for the value-kind table the Markdown
    // and IR channels render, and a head-set kind is reusable across
    // slots with different local registries. An absent `slot` says so.
    shape: lowerValueKind(ctx, plugin, vk, { pluginName: plugin.name }),
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

  // Positional slot-local forms, lowered *before* the positional kind
  // because a head-set resolution embeds these bodies. Mirrors the Zig
  // `lowerForm` hook.
  const localSpecs: readonly FormSpec[] = form.localForms ?? [];
  const slot: SlotLocals = {
    specs: localSpecs,
    lowered: localSpecs.map((lf) => lowerForm(ctx, plugin, lf)),
  };

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
          slot,
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

  if (localSpecs.length > 0) {
    // A declared head-set closes the slot by head text, and the
    // resolution above has already embedded each local body into the
    // matching member — keeping it is what preserves the narrowing, the
    // `x-sjon-head-set` annotation and the per-head `contains` bounds.
    // Anything else places no head constraint, so the locals open the
    // slot additively (inline union + trailing open generic branch).
    // The loader guarantees only `any` and `kind` reach here with a
    // non-empty registry. Mirrors the Zig `lowerForm` hook.
    const headSet =
      positional.kind === 'kind' && positional.shape.kind === 'form_heads'
        ? positional.shape.heads
        : null;
    if (headSet === null) {
      positional = { kind: 'kind', shape: { kind: 'form_locals', forms: slot.lowered } };
    } else {
      // A local outside the set is dead: narrowing rejects the head
      // (`not_head_member`) before resolution reaches the registry.
      for (const lf of localSpecs) {
        if (headSet.some((ref) => ref.name === lf.name)) continue;
        ctx.warnings.push(
          makeWarning(
            'local_form_outside_head_set',
            'warn',
            `positional slot-local form \`${lf.name}\` on \`${form.name}\` is outside the slot's head-set, so no child can ever reach it — add \`${lf.name}\` to the head-set or delete the local`,
            { pluginName: plugin.name, formName: form.name },
          ),
        );
      }
    }
    ctx.warnings.push(
      makeWarning(
        'local_forms_emitted_inline',
        'info',
        headSet === null
          ? `positional slot on form \`${form.name}\` declares ${localSpecs.length} local form(s) — emitted as an inline union plus an open generic branch for the additive global fallback; local-first/global resolution order is SJON-only`
          : `positional slot on form \`${form.name}\` declares ${localSpecs.length} local form(s) behind a ${headSet.length}-head head-set — emitted as a closed inline union with no global fallback branch; a head outside the set is \`not_head_member\``,
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
    slot: NO_LOCALS,
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

function lowerValueKind(
  ctx: LowerCtx,
  plugin: Plugin,
  vk: ValueKind,
  /**
   * The site this kind is being lowered *for*. Callers pass their own
   * scope rather than one minted here, so a head-set kind reached
   * through a union alternative still knows which slot it landed in.
   */
  outer: LowerScope,
): ModelValueShape {
  // Refinement axes layered onto the underlying type. Order matters —
  // unit-with-numeric pulls bounds into the unit shape; numeric-only
  // routes through number_bounded; etc.
  // Two scopes, deliberately. `scope` is the *warning* scope and is
  // kind-only, exactly as before slot-aware resolution: widening it would
  // put the caller's form and key on every warning this function emits,
  // which un-collapses `dedupeWarnings` for a kind referenced from a slot
  // *and* from the standalone value-kind pass — one cross-ref would warn
  // twice. `inner` is the *resolution* scope, and carries the slot on to
  // anything that recurses.
  const scope: LowerScope = { pluginName: plugin.name, kindName: vk.name };
  const inner: LowerScope = { ...scope, ...(outer.slot ? { slot: outer.slot } : {}) };
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
      shape: resolveNamedShape(ctx, plugin, alt.name, alt.namespace, inner),
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
  if (vk.heads && vk.heads.heads.length > 0) {
    // Head-set resolution, the way `Validator.validateFormHead` step 0
    // resolves the child that will carry the head: slot-local first,
    // global catalog second. `scope.slot` is what makes that possible and
    // what decides whether a miss is reported at all — a slot judges, the
    // standalone value-kind pass stays quiet (see `LowerScope`).
    let localCount = 0;
    const heads = vk.heads.heads.map((entry) => {
      const ref: ModelFormRef = {
        plugin: '',
        name: entry.name,
        ...(entry.min !== undefined ? { min: entry.min } : {}),
        ...(entry.max !== undefined ? { max: entry.max } : {}),
      };
      const local = matchSlotLocal(outer, entry.name);
      if (local) {
        localCount += 1;
        // A slot-local belongs to the plugin whose form declares it,
        // which is the plugin being lowered — locals never cross a
        // plugin boundary.
        return { ...ref, plugin: plugin.name, body: { kind: 'local', form: local } as const };
      }
      const hit = lookupForm(ctx.schema, entry.name, null);
      if (hit.kind === 'found') {
        return { ...ref, plugin: findOwningPlugin(ctx.schema, hit.value) ?? plugin.name };
      }
      if (scopeJudges(outer)) {
        ctx.warnings.push(
          makeWarning(
            'head_set_member_unresolved',
            'err',
            hit.kind === 'ambiguous'
              ? `head-set member \`${entry.name}\` on value-kind \`${vk.name}\` is declared by more than one plugin; qualify it or rename one`
              : `head-set member \`${entry.name}\` on value-kind \`${vk.name}\` resolves to no form in scope at this slot — no slot-local \`(form :name ${entry.name} …)\` and no global one`,
            // The err names the slot, which the kind-scoped message it
            // replaced could not. Mirrors the Zig warning's fields.
            {
              ...scope,
              ...(outer.formName ? { formName: outer.formName } : {}),
              ...(outer.keyName ? { keyName: outer.keyName } : {}),
            },
          ),
        );
      }
      return { ...ref, body: { kind: 'unresolved' } as const };
    });
    // Scoped to slots for the same reason the miss above is: the note
    // describes how a *slot's* `$children` was emitted, and the standalone
    // value-kind pass emits no `$children` anywhere. Left unscoped it fired
    // twice per locals-backed head-set. Mirrors the Zig guard.
    // The set's own count travels with the members, since it belongs to
    // the set rather than to any of them. Mirrors `Model.HeadSetShape`.
    const shape: ModelValueShape = {
      kind: 'form_heads',
      heads,
      ...(vk.heads.minChildren !== undefined ? { minChildren: vk.heads.minChildren } : {}),
      ...(vk.heads.maxChildren !== undefined ? { maxChildren: vk.heads.maxChildren } : {}),
    };
    if (!scopeJudges(outer)) return shape;
    ctx.warnings.push(
      makeWarning(
        'head_set_emitted_via_oneof_refs',
        'info',
        localCount === 0
          ? `value-kind \`${vk.name}\` — head-set emitted as \`oneOf\` of \`$ref\`s into \`#/$defs/form.<plugin>.<head>\``
          : `value-kind \`${vk.name}\` head-set emitted as a closed \`oneOf\` — ${localCount} of ${vk.heads.heads.length} head(s) resolve to slot-local forms and are emitted inline, the rest as \`$ref\`s into \`#/$defs/form.<plugin>.<head>\``,
        localCount === 0 || !outer.formName ? scope : { ...scope, formName: outer.formName },
      ),
    );
    return shape;
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
          // An element is a value, not a form child, so the enclosing
          // slot's registry does not reach it — matching the validator,
          // which attaches one only to a direct `.form` child.
          { ...inner, slot: NO_LOCALS },
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
  scope: LowerScope,
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
  scope: LowerScope,
): ModelValueShape {
  // Primitive-name shortcut — the TS plugin model lets keys reference
  // `number` / `string` / etc. via `{kind: 'named', name: 'number'}`.
  const primitive = primitiveShortcut(name);
  if (primitive) return primitive;

  const hit = lookupValueKind(ctx.schema, name, namespace);
  if (hit.kind === 'found') {
    return lowerValueKind(ctx, plugin, hit.value, scope);
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
  scope: LowerScope,
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

function lowerBound(ctx: LowerCtx, src: NumericBound, scope: LowerScope): ModelNumericBound {
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
