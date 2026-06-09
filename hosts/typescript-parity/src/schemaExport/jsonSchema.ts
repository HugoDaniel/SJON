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
// What this port does NOT yet reproduce byte-for-byte:
//
//   * Variants (discriminator → allOf+if/then) — IR field is null
//     because the TS-parity loader doesn't parse the construct
//   * Exclusive groups (oneOf / not:{allOf}) — same reason
//   * Union-of (anyOf) — same
//
// When `loader.ts` learns those constructs, the per-shape helpers
// below cover the IR cases unconditionally.

import type { Member } from '../plugin.ts';
import type {
  Model,
  ModelForm,
  ModelKey,
  ModelMember,
  ModelNumericBounds,
  ModelPlugin,
  ModelStringBounds,
  ModelUnitShape,
  ModelValueShape,
} from './model.ts';
import type { Warning } from './warnings.ts';
import { assertNever } from './internal.ts';

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
    case 'kind':
      properties['$children'] = {
        type: 'array',
        items: buildShape(form.positional.shape, formCtx),
      };
      break;
    default:
      assertNever(form.positional);
  }
  const required: string[] = ['$form'];
  for (const k of form.keys) {
    if (!k.optional) required.push(escapeFieldName(k.name));
  }
  const out: Record<string, unknown> = {
    type: 'object',
    properties,
    required,
    additionalProperties: form.open,
  };
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

function buildKey(key: ModelKey, ctx: EmitContext): Record<string, unknown> {
  const shape = buildShape(key.value, ctx);
  if (key.default) {
    // M1 attaches literal defaults as a JSON `default:` keyword on
    // the per-key schema. Expression defaults are recorded by the
    // lowering pass as a warning + annotation; no `default:` keyword.
    const def = serializeDefault(key.default);
    if (def !== undefined && typeof shape === 'object' && shape !== null) {
      (shape as Record<string, unknown>)['default'] = def;
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
      const refs = shape.heads.map((head) => {
        if (ctx.filterPlugin && head.plugin && head.plugin !== ctx.filterPlugin) {
          return { $ref: `./${head.plugin}.schema.json#/$defs/form.${head.plugin}.${head.name}` };
        }
        return { $ref: `#/$defs/form.${head.plugin || ''}.${head.name}` };
      });
      const headSetAnnotation = shape.heads.map((h) => h.name);
      return { oneOf: refs, 'x-sjon-head-set': headSetAnnotation };
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
    case 'cross_ref':
      return {
        type: 'object',
        required: ['$sym'],
        properties: { $sym: { type: 'string' } },
        additionalProperties: false,
        'x-sjon-cross-ref': {
          'target-form': shape.crossRef.targetForm,
          'name-key': shape.crossRef.nameKey,
          acyclic: shape.crossRef.acyclic,
          'scope-form': shape.crossRef.scopeForm,
        },
      };
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

function buildRichMember(m: ModelMember, underlying: 'symbol' | 'string'): Record<string, unknown> {
  const out: Record<string, unknown> = {
    const: underlying === 'symbol' ? { $sym: m.name } : m.name,
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
