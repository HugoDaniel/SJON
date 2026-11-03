// Model → TypeScript `.d.ts` bytes — TypeScript port of
// `src/SchemaExport/TsTypes.zig`.
//
// Emits one interface or type alias per form (`<Plugin>_<Form>`
// PascalCase — an interface for the plain shapes, an alias whose
// anonymous base is intersected by arm unions when an exclusive group is
// structurally enforced), one type alias per value-kind, a
// `Sjon<Plugin>` barrel union per plugin. The output describes the
// canonical JSON shape of `sjon to-json` — `$form`, `$ns`, `$kw`,
// `$sym`, etc.
//
// Structural parity with Zig:
//
//   * Same brand definitions (`Keyword<>`, `Symbol_<>`, `SjonDate`,
//     `SjonTime`, `SjonExpr<>`, `CrossRef<>`)
//   * Same form-naming scheme: `<Plugin>_<Form>` PascalCase
//   * Same per-key/per-shape mapping: optional `?`, literal `$form`,
//     branded `Symbol_<>` for members, tuple `readonly [number, "deg"]`
//     for unit-bearing numbers, JSDoc `@minimum`/`@maximum`/
//     `@minLength`/`@maxLength`/`@pattern`/`@format`/`@sjon-unit`/
//     `@sjon-cross-ref` annotations
//
// Discriminated forms and exclusive groups are emitted here too, now that
// `loader.ts` parses them: a discriminated form becomes a per-variant union
// (`writeDiscriminatedFormType`) and every group adds a
// `@sjon-exclusive-group` JSDoc line. On the fixtures wired into
// `test/schemaExport.test.ts` (kit, kit-xor, variant-set, the group-*
// family, local-forms) the output is byte-identical to the Zig goldens —
// including `:description` text, which this port's loader reads.

import type {
  Model,
  ModelCrossRef,
  ModelDiscriminator,
  ModelExclusiveGroup,
  ModelForm,
  ModelKey,
  ModelMember,
  ModelNumericBounds,
  ModelPlugin,
  ModelStringBounds,
  ModelUnitShape,
  ModelValueShape,
} from './model.ts';
import { anyBoundedInSet, isBoundedRef, isBoundedSet, refBody } from './model.ts';
import type { Warning } from './warnings.ts';
import type { Repr } from '../plugin.ts';
import { assertNever } from '../internal.ts';

// Branded TS alias for a GPU representation tag. The aliases are defined
// in BRAND_PRELUDE; this maps the `Repr` union to the alias name so a
// `:repr`-tagged number renders as `F32` … `F16` instead of `number`.
// Exhaustive switch (no default): a new `Repr` is a noImplicitReturns error.
function reprTsAlias(repr: Repr): string {
  switch (repr) {
    case 'f32':
      return 'F32';
    case 'u32':
      return 'U32';
    case 'i32':
      return 'I32';
    case 'u16':
      return 'U16';
    case 'f16':
      return 'F16';
  }
}

const BRAND_PRELUDE = `
export type Keyword<S extends string = string> = { readonly $kw: S };
export type Symbol_<S extends string = string> = { readonly $sym: S };
export type SjonDate = { readonly $date: string };
export type SjonTime = { readonly $time: string };
export type SjonExpr<TResult = unknown> = { readonly $expr: unknown[] } & { readonly __sjonResult?: TResult };
export type CrossRef<TargetForm extends string = string, S extends string = string> = Symbol_<S> & { readonly __sjonRef?: TargetForm };
export type F32 = number & { readonly __sjonRepr?: "f32" };
export type U32 = number & { readonly __sjonRepr?: "u32" };
export type I32 = number & { readonly __sjonRepr?: "i32" };
export type U16 = number & { readonly __sjonRepr?: "u16" };
export type F16 = number & { readonly __sjonRepr?: "f16" };
`;

interface EmitContext {
  readonly filterPlugin: string | null;
  readonly model: Model;
}

export function emit(model: Model, warnings: readonly Warning[]): string {
  return emitWithContext(model, warnings, { filterPlugin: null, model });
}

export function emitForPlugin(
  model: Model,
  plugin: ModelPlugin,
  warnings: readonly Warning[],
): string {
  return emitWithContext(model, warnings, { filterPlugin: plugin.name, model });
}

/** The `_SjonNotAll` helper, spelled exactly as it must appear once per
 *  output file: directly after the brand prelude, non-exported, only when
 *  that file contains at least one structurally enforced group. The
 *  underscore prefix avoids the barrel a plugin literally named `not-all`
 *  would produce (`SjonNotAll`). */
const NOT_ALL_HELPER_DECL =
  'type _SjonNotAll<K extends string> = K extends K ? { [P in K]?: never } : never;';

function emitWithContext(model: Model, warnings: readonly Warning[], ctx: EmitContext): string {
  let out = '';
  out += writeHeader(model.version, warnings);
  out += BRAND_PRELUDE;
  // The helper rides directly under the brand prelude and before
  // imports/forms, once, and only when something in this file will
  // actually reference it.
  if (fileHasEnforcedGroup(model, ctx.filterPlugin)) {
    out += NOT_ALL_HELPER_DECL + '\n';
  }
  out += '\n';
  if (ctx.filterPlugin) {
    out += writeCrossPluginImports(model, ctx.filterPlugin);
  }
  for (const p of model.plugins) {
    if (ctx.filterPlugin && p.name !== ctx.filterPlugin) continue;
    out += `\n// ----- plugin: ${p.name} -----\n\n`;
    for (const f of p.forms) {
      out += writeForm(p, f, ctx);
    }
    out += writeBarrel(p);
  }
  return out;
}

function writeHeader(version: number, warnings: readonly Warning[]): string {
  let out = `// sjon-export-version: ${version}\n`;
  out += '// Generated by sjon — do not edit by hand.\n';
  out += '// Describes the canonical JSON shape of `sjon to-json`.\n';
  if (warnings.length > 0) {
    out += '//\n// Export warnings:\n';
    for (const w of warnings) {
      out += `//   [${w.severity} ${w.code}] ${w.message}\n`;
    }
  }
  return out;
}

function writeCrossPluginImports(model: Model, thisPlugin: string): string {
  const seen = new Map<string, Set<string>>();
  for (const p of model.plugins) {
    if (p.name !== thisPlugin) continue;
    for (const f of p.forms) {
      collectCrossPluginRefsFromForm(f, thisPlugin, seen);
    }
  }
  if (seen.size === 0) return '';
  let out = '';
  for (const [otherPlugin, names] of seen) {
    const sortedNames = [...names].sort();
    const idents = sortedNames.map((n) => formTypeName(otherPlugin, n)).join(', ');
    out += `import type { ${idents} } from "./${otherPlugin}";\n`;
  }
  return out + '\n';
}

function collectCrossPluginRefsFromForm(
  form: ModelForm,
  thisPlugin: string,
  seen: Map<string, Set<string>>,
): void {
  for (const k of form.keys) {
    collectCrossPluginRefsFromShape(k.value, thisPlugin, seen);
  }
  // Variant keys emit into the same file and so need the same imports.
  for (const v of form.discriminator?.variants ?? []) {
    for (const k of v.keys) collectCrossPluginRefsFromShape(k.value, thisPlugin, seen);
  }
  if (form.positional.kind === 'kind') {
    collectCrossPluginRefsFromShape(form.positional.shape, thisPlugin, seen);
  }
}

function collectCrossPluginRefsFromShape(
  shape: ModelValueShape,
  thisPlugin: string,
  seen: Map<string, Set<string>>,
): void {
  switch (shape.kind) {
    case 'form_heads':
      for (const head of shape.heads) {
        // Only a global head names a type in another file. A local body is
        // emitted inline (same as `form_locals`, which this walk also
        // skips) and an unresolved head names nothing at all.
        if (refBody(head).kind !== 'global') continue;
        if (!head.plugin || head.plugin === thisPlugin) continue;
        if (!seen.has(head.plugin)) seen.set(head.plugin, new Set());
        seen.get(head.plugin)!.add(head.name);
      }
      break;
    case 'vector':
      collectCrossPluginRefsFromShape(shape.vector.element, thisPlugin, seen);
      break;
    case 'union_of':
      for (const alt of shape.alternatives) {
        collectCrossPluginRefsFromShape(alt.shape, thisPlugin, seen);
      }
      break;
    default:
      break;
  }
}

function writeForm(plugin: ModelPlugin, form: ModelForm, ctx: EmitContext): string {
  const doc = writeFormDoc(form);
  if (form.discriminator) {
    return doc + writeDiscriminatedFormType(plugin, form, form.discriminator, ctx);
  }
  if (hasEnforcedFormGroup(form)) {
    return doc + writeFormType(plugin, form, ctx);
  }
  return doc + writeFormInterface(plugin, form, ctx);
}

/** True when at least one form-level group on `form` is structurally
 *  enforced (closed scope, no defaulted alternative key). */
function hasEnforcedFormGroup(form: ModelForm): boolean {
  return form.exclusiveGroups.some((g) => groupState(form, g) === 'enforced');
}

/** True when `name` is claimed by any enforced group over `scopeKeys`
 *  (the form's keys, or one variant's overlay). Only enforced groups
 *  take their keys out of the base — a defaulted or open group leaves
 *  every key where the interface spelling put it. */
function isKeyGroupedEnforced(
  open: boolean,
  scopeKeys: readonly ModelKey[],
  groups: readonly ModelExclusiveGroup[],
  name: string,
): boolean {
  for (const g of groups) {
    if (groupStateForScope(open, scopeKeys, g) !== 'enforced') continue;
    for (const alt of g.alternatives) {
      if (alt.includes(name)) return true;
    }
  }
  return false;
}

/** The `ModelKey` named `name` in `scopeKeys`, or undefined. The manifest
 *  guarantees every alternative name resolves in its scope; the undefined
 *  arm only exists for hand-built models. */
function scopeKey(keys: readonly ModelKey[], name: string): ModelKey | undefined {
  return keys.find((k) => k.name === name);
}

/** Whether this file needs `_SjonNotAll`: any enforced group anywhere in
 *  the emitted forms — form-level, variant-scoped, or on a slot-local
 *  form reached through a compound shape. */
function fileHasEnforcedGroup(model: Model, filterPlugin: string | null): boolean {
  for (const p of model.plugins) {
    if (filterPlugin && p.name !== filterPlugin) continue;
    for (const f of p.forms) {
      if (formHasEnforcedGroup(f)) return true;
    }
  }
  return false;
}

function formHasEnforcedGroup(form: ModelForm): boolean {
  if (hasEnforcedFormGroup(form)) return true;
  if (form.discriminator) {
    for (const v of form.discriminator.variants) {
      for (const g of v.exclusiveGroups) {
        if (groupStateForScope(form.open, v.keys, g) === 'enforced') return true;
      }
    }
  }
  for (const k of form.keys) {
    if (shapeHasEnforcedGroup(k.value)) return true;
  }
  return form.positional.kind === 'kind' && shapeHasEnforcedGroup(form.positional.shape);
}

function shapeHasEnforcedGroup(shape: ModelValueShape): boolean {
  switch (shape.kind) {
    case 'vector':
      return shapeHasEnforcedGroup(shape.vector.element);
    case 'union_of':
      return shape.alternatives.some((alt) => shapeHasEnforcedGroup(alt.shape));
    case 'form_locals':
      return shape.forms.some((form) => formHasEnforcedGroup(form));
    case 'form_heads':
      return shape.heads.some((head) => {
        const body = refBody(head);
        return body.kind === 'local' && formHasEnforcedGroup(body.form);
      });
    default:
      return false;
  }
}

/** Column geometry for the block-shaped arm union. The top-level alias
 *  puts pipes at column 2; a variant branch nests four deeper. */
interface ArmLayout {
  readonly pipe: string;
  readonly key: string;
  readonly close: string;
  readonly cont: string;
}

const arm_layout_top: ArmLayout = {
  pipe: '  ',
  key: '      ',
  close: '    ',
  cont: '      ',
};

const arm_layout_variant: ArmLayout = {
  pipe: '      ',
  key: '          ',
  close: '        ',
  cont: '          ',
};

/** A form with at least one enforced exclusive group emits as an
 *  anonymous-base type alias intersected by one arm-union per group, in
 *  declaration order:
 *
 *      export type P_Choice = { base } & (arms…) & (arms…);
 *
 *  Grouped keys leave the base — even `:optional false` ones — because
 *  only an active arm may require them; ordinary base keys keep the
 *  interface path's sorted emission. Skipped groups (open, defaulted)
 *  contribute no intersection and keep their keys in the base. Mirrors
 *  `writeFormType` in `src/SchemaExport/TsTypes.zig`. */
function writeFormType(plugin: ModelPlugin, form: ModelForm, ctx: EmitContext): string {
  let out = `export type ${formTypeName(plugin.name, form.name)} = {\n`;
  out += `  $form: "${form.name}";\n`;
  out += `  $ns: "${plugin.name}";\n`;
  for (const k of sortKeys(form.keys)) {
    if (isKeyGroupedEnforced(form.open, form.keys, form.exclusiveGroups, k.name)) continue;
    out += writeKey(k, '  ', ctx);
  }
  out += writeChildren(form, '  ', ctx);
  out += '}';
  let first = true;
  for (const g of form.exclusiveGroups) {
    if (groupState(form, g) !== 'enforced') continue;
    out += first ? ' & (\n' : ') & (\n';
    first = false;
    out += writeGroupArms(form.keys, g, arm_layout_top, ctx);
  }
  out += ');\n\n';
  return out;
}

/** The arm union of one enforced group, one line per arm at `layout`'s
 *  pipe column (`at_most_one` leads with the none-arm). The caller
 *  writes the wrapping `& (\n` before and `)` after. */
function writeGroupArms(
  scopeKeys: readonly ModelKey[],
  group: ModelExclusiveGroup,
  layout: ArmLayout,
  ctx: EmitContext,
): string {
  let out = '';
  if (group.cardinality === 'at_most_one') {
    out += layout.pipe + '| { ';
    let first = true;
    for (const alt of group.alternatives) {
      for (const kn of alt) {
        if (!first) out += '; ';
        first = false;
        out += escapeIdentifier(kn) + '?: never';
      }
    }
    out += ' }\n';
  }
  for (let i = 0; i < group.alternatives.length; i++) {
    out += layout.pipe + '| ' + writeArm(scopeKeys, group, i, layout, false, ctx) + '\n';
  }
  return out;
}

/** The same arm union on one line, for an inline local-form literal:
 *  `({ a: number } & _SjonNotAll<"b">) | ({ b: number } & _SjonNotAll<"a">)`.
 *  The caller writes the wrapping ` & (` and `)`. */
function writeGroupArmsInline(
  scopeKeys: readonly ModelKey[],
  group: ModelExclusiveGroup,
  ctx: EmitContext,
): string {
  let out = '';
  let wrote = false;
  if (group.cardinality === 'at_most_one') {
    out += '{';
    let first = true;
    for (const alt of group.alternatives) {
      for (const kn of alt) {
        out += first ? ' ' : '; ';
        first = false;
        out += escapeIdentifier(kn) + '?: never';
      }
    }
    out += ' }';
    wrote = true;
  }
  for (let i = 0; i < group.alternatives.length; i++) {
    if (wrote) out += ' | ';
    wrote = true;
    out += writeArm(scopeKeys, group, i, arm_layout_top, true, ctx);
  }
  return out;
}

/** One alternative's arm: the alternative's keys required (original
 *  value types, original JSDoc) intersected with one `_SjonNotAll<…>` per
 *  competing alternative, in declaration order — never one flattened key
 *  set, which a partial competitor would slip through. */
function writeArm(
  scopeKeys: readonly ModelKey[],
  group: ModelExclusiveGroup,
  altIndex: number,
  layout: ArmLayout,
  oneLine: boolean,
  ctx: EmitContext,
): string {
  const alt = group.alternatives[altIndex]!;
  const multi = !oneLine && (group.alternatives.length > 2 || armNeedsDoc(scopeKeys, alt));
  let out = '';
  if (!multi) {
    out += '({ ';
    let first = true;
    for (const kn of alt) {
      if (!first) out += '; ';
      first = false;
      const k = scopeKey(scopeKeys, kn);
      if (k) {
        out += escapeIdentifier(k.name) + ': ' + writeShape(k.value, ctx);
      } else {
        out += escapeIdentifier(kn) + ': unknown';
      }
    }
    out += ' }';
    for (let j = 0; j < group.alternatives.length; j++) {
      if (j === altIndex) continue;
      out += ' & ' + writeNotAllArg(group.alternatives[j]!);
    }
    out += ')';
    return out;
  }
  out += '({\n';
  for (const kn of alt) {
    const k = scopeKey(scopeKeys, kn) ?? {
      name: kn,
      optional: false,
      description: '',
      value: { kind: 'any' } as const,
      default: null,
      requires: [],
    };
    out += writeKey({ ...k, optional: false }, layout.key, ctx);
  }
  let n = 0;
  const competitors = group.alternatives.length - 1;
  for (let j = 0; j < group.alternatives.length; j++) {
    if (j === altIndex) continue;
    if (n === 0) {
      out += layout.close + '} & ';
    } else {
      out += '\n' + layout.cont + '& ';
    }
    out += writeNotAllArg(group.alternatives[j]!);
    n += 1;
    if (n === competitors) out += ')';
  }
  if (n === 0) out += layout.close + '})';
  return out;
}

/** `_SjonNotAll<"b1" | "b2">` — one competing alternative's key bundle. */
function writeNotAllArg(altNames: readonly string[]): string {
  return `_SjonNotAll<${altNames.map((kn) => `"${kn}"`).join(' | ')}>`;
}

/** True when any key of `alt` carries the JSDoc that forces the
 *  multi-line arm shape. */
function armNeedsDoc(scopeKeys: readonly ModelKey[], alt: readonly string[]): boolean {
  return alt.some((kn) => {
    const k = scopeKey(scopeKeys, kn);
    return k !== undefined && keyNeedsDoc(k);
  });
}

function writeFormInterface(plugin: ModelPlugin, form: ModelForm, ctx: EmitContext): string {
  let out = `export interface ${formTypeName(plugin.name, form.name)} {\n`;
  out += `  $form: "${form.name}";\n`;
  out += `  $ns: "${plugin.name}";\n`;
  // Sort keys alphabetically (mirrors Zig's sortKeysAlphabetically).
  for (const k of sortKeys(form.keys)) {
    out += writeKey(k, '  ', ctx);
  }
  out += writeChildren(form, '  ', ctx);
  if (form.open) {
    out += '  [key: string]: unknown;\n';
  }
  out += '}\n\n';
  return out;
}

/**
 * A discriminated form is a `type` union, one branch per variant, not an
 * `interface`: the discriminant is branded to the variant's `:when`, so TS
 * narrows the branch — and with it the variant-only keys — from the value of
 * one property. An interface with every variant key optional would type-check
 * a document mixing two variants, which is the thing the discriminant exists
 * to forbid. Mirrors `writeDiscriminatedFormType` in
 * `src/SchemaExport/TsTypes.zig`.
 */
function writeDiscriminatedFormType(
  plugin: ModelPlugin,
  form: ModelForm,
  disc: ModelDiscriminator,
  ctx: EmitContext,
): string {
  let out = `export type ${formTypeName(plugin.name, form.name)} =`;
  // A form-level enforced group constrains keys every branch repeats, so
  // it intersects the whole union — parenthesised, because `|` binds
  // looser than `&` and a bare branch tail would constrain only the last
  // branch. Mirrors the JSON Schema side's allOf chain.
  const wrap = hasEnforcedFormGroup(form);
  if (wrap) out += ' (';
  for (const v of disc.variants) {
    out += writeDiscriminatedBranch(plugin, form, disc, v.when, v.keys, v.exclusiveGroups, ctx);
  }
  // Members no variant selects get one residual branch — common keys only,
  // discriminant narrowed to exactly those members — so the union covers the
  // whole member set the validator accepts. Mirrors Zig.
  const residual = residualMembers(form, disc);
  if (residual.length > 0)
    out += writeDiscriminatedBranch(plugin, form, disc, residual, [], [], ctx);
  if (wrap) {
    out += '\n)';
    for (const g of form.exclusiveGroups) {
      if (groupState(form, g) !== 'enforced') continue;
      out += ' & (\n';
      out += writeGroupArms(form.keys, g, arm_layout_top, ctx);
      out += ')';
    }
  }
  return `${out};\n\n`;
}

/** One `| { … }` branch of a discriminated form's union: `$form`/`$ns`,
 *  the common keys with the discriminant narrowed to `when`, then
 *  `overlay` (a variant's keys, or none for the residual branch). A
 *  variant carrying scoped exclusive groups gets their annotation as a
 *  doc block above the branch — the group constrains that variant's keys
 *  only, so the form-level doc and the residual branch stay clean. When
 *  any of those groups is enforced, the branch object becomes an
 *  anonymous base intersected by the group's arm union (`| ({ … } & (…))`);
 *  form-level enforced groups remove their keys from every branch
 *  instead, their arms riding outside the union. Mirrors
 *  `writeDiscriminatedBranch` in `src/SchemaExport/TsTypes.zig`. */
function writeDiscriminatedBranch(
  plugin: ModelPlugin,
  form: ModelForm,
  disc: ModelDiscriminator,
  when: readonly string[],
  overlay: readonly ModelKey[],
  groups: readonly ModelExclusiveGroup[],
  ctx: EmitContext,
): string {
  const anyEnforced = groups.some((g) => groupStateForScope(form.open, overlay, g) === 'enforced');
  let out = '';
  if (groups.length > 0) {
    out += '\n  /**\n';
    out += exclusiveGroupLines(groups, '  ');
    out += '  */\n';
    out += anyEnforced ? '  | ({\n' : '  | {\n';
  } else {
    out += '\n  | {\n';
  }
  out += `      $form: "${form.name}";\n`;
  out += `      $ns: "${plugin.name}";\n`;
  // Common + discriminant keys, sorted alphabetically. The discriminant
  // gets its brand narrowed to the branch's `when`; keys claimed by a
  // form-level enforced group leave for its arms.
  for (const k of sortKeys(form.keys)) {
    if (isKeyGroupedEnforced(form.open, form.keys, form.exclusiveGroups, k.name)) continue;
    out +=
      k.name === disc.keyName
        ? writeDiscriminantKey(k, when, '      ')
        : writeKey(k, '      ', ctx);
  }
  // Variant overlay keys; those claimed by an enforced variant group leave
  // the base for that group's arms.
  for (const vk of sortKeys(overlay)) {
    if (isKeyGroupedEnforced(form.open, overlay, groups, vk.name)) continue;
    out += writeKey(vk, '      ', ctx);
  }
  out += writeChildren(form, '      ', ctx);
  if (form.open) out += '      [key: string]: unknown;\n';
  if (anyEnforced) {
    // The base object closes exactly once, before the first enforced
    // group's union; each further group joins with `) & (`. Mirrors the
    // Zig emitter — a `} & (` per group emits a stray brace for every
    // group after the first and the file does not parse.
    let firstGroup = true;
    for (const g of groups) {
      if (groupStateForScope(form.open, overlay, g) !== 'enforced') continue;
      out += firstGroup ? '    } & (\n' : '    ) & (\n';
      firstGroup = false;
      out += writeGroupArms(overlay, g, arm_layout_variant, ctx);
    }
    out += '    ))';
  } else {
    out += '    }';
  }
  return out;
}

/** Every member of the discriminant's set that no variant's `:when` lists —
 *  the values that validate with common keys only. Empty when the variants
 *  cover the set (or the discriminant key is not a symbol member-set, which
 *  `discriminant_not_closed_enum` keeps from reaching export). Mirrors
 *  `memberNameAt` + `variantCovers` in `src/SchemaExport/TsTypes.zig`. */
function residualMembers(form: ModelForm, disc: ModelDiscriminator): string[] {
  const key = form.keys.find((k) => k.name === disc.keyName);
  if (!key) return [];
  const shape = key.value;
  const names =
    shape.kind === 'symbol_members'
      ? shape.members
      : shape.kind === 'symbol_members_rich'
        ? shape.members.map((m) => m.name)
        : [];
  return names.filter((n) => !disc.variants.some((v) => v.when.includes(n)));
}

function sortKeys(keys: readonly ModelKey[]): ModelKey[] {
  return [...keys].sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * TypeScript cannot express "exactly one element of this union in an
 * array", so a bounded head-set's counts ride as a doc comment above the
 * `$children` member and nothing more. Documented as a known weakening in
 * `docs/SCHEMA_EXPORT.md`: a silently weaker `.d.ts` is worse than a
 * documented one. Returns the empty string when nothing is bounded.
 *
 * The inline local-form literal is deliberately not given one — that
 * surface carries no JSDoc at all, by design. Mirrors Zig's
 * `writeChildCountsDoc`.
 */
function childCountsDoc(shape: ModelValueShape, indent: string): string {
  if (shape.kind !== 'form_heads') return '';
  if (!anyBoundedInSet(shape)) return '';
  const parts = shape.heads
    .filter(isBoundedRef)
    .map((h) => `${h.name}: ${countRange(h.min ?? 0, h.max)}`);
  // The set's own count, named `any of the set` rather than by a head — a
  // reader has to be able to tell "at most one buffer" from "at most one
  // resource of any kind" when both sit on one line. Mirrors Zig.
  if (isBoundedSet(shape)) {
    parts.push(`any of the set: ${countRange(shape.minChildren ?? 0, shape.maxChildren)}`);
  }
  return `${indent}/** Positional counts (not expressible in TS): ${parts.join('; ')} */\n`;
}

/** `2` for an exact count, `0..1` for a range, `1..` for a floor with no
 *  ceiling. Shared by the per-head entries and the set's so the two read
 *  alike on one line. Mirrors Zig's `writeCountRange`. */
function countRange(min: number, max: number | undefined): string {
  if (max === undefined) return `${min}..`;
  return max === min ? `${max}` : `${min}..${max}`;
}

/** The `$children` line for a form's positional slot, shared by the interface
 *  and per-variant-branch emitters (the positional is form-level — a variant
 *  overlays keys, never children). */
function writeChildren(form: ModelForm, indent: string, ctx: EmitContext): string {
  switch (form.positional.kind) {
    case 'none':
      return '';
    case 'any':
      return `${indent}$children?: unknown[];\n`;
    case 'kind':
      return (
        childCountsDoc(form.positional.shape, indent) +
        `${indent}$children?: Array<${writeShape(form.positional.shape, ctx)}>;\n`
      );
    default:
      return assertNever(form.positional);
  }
}

/** The discriminant key inside a variant branch: narrowed to that branch's
 *  `:when` values rather than the whole member set, which is what makes the
 *  union discriminate. */
function writeDiscriminantKey(key: ModelKey, when: readonly string[], indent: string): string {
  const doc = key.description ? `${indent}/** ${key.description} */\n` : '';
  return `${doc}${indent}${escapeIdentifier(key.name)}: ${whenBrand(when)};\n`;
}

/** `Symbol_<"a">` for a one-value variant, `Symbol_<"a" | "b">` for a
 *  multi-value one — the brand's `S extends string` parameter takes a literal
 *  union, so one field spells the whole set. Mirrors `writeWhenBrand`. */
function whenBrand(when: readonly string[]): string {
  return `Symbol_<${when.map((w) => `"${w}"`).join(' | ')}>`;
}

function writeFormDoc(form: ModelForm): string {
  if (!form.description && form.exclusiveGroups.length === 0) return '';
  if (form.description && form.exclusiveGroups.length === 0) {
    return `/** ${form.description} */\n`;
  }
  let out = '/**\n';
  if (form.description) {
    out += ` * ${form.description}\n`;
    if (form.exclusiveGroups.length > 0) out += ' *\n';
  }
  out += exclusiveGroupLines(form.exclusiveGroups, '');
  out += ' */\n';
  return out;
}

export type GroupState = 'enforced' | 'skipped-open' | 'defaulted';

/** Form-scoped eligibility decision. */
export function groupState(form: ModelForm, group: ModelExclusiveGroup): GroupState {
  return groupStateForScope(form.open, form.keys, group);
}

/** The scope a group constrains: a form's keys, or one variant's overlay
 *  keys. `open` is the scope's own openness. */
export function groupStateForScope(
  open: boolean,
  keys: readonly ModelKey[],
  group: ModelExclusiveGroup,
): GroupState {
  // An open scope round-trips unknown keys, and the runtime bypasses the
  // group sweep for it, so a structural arm here would reject documents
  // the validator accepts. Skipping wins over the default check: either
  // way the group contributes no arm.
  if (open) return 'skipped-open';
  for (const alternative of group.alternatives) {
    for (const name of alternative) {
      // Any defaulted alternative skips the *whole* group, not just that
      // alternative: defaulted participation depends on whether a sibling
      // is fully author-present, so the ordinary presence union is not
      // equivalent.
      if (scopeKeyHasDefault(keys, name)) return 'defaulted';
    }
  }
  return 'enforced';
}

function scopeKeyHasDefault(keys: readonly ModelKey[], name: string): boolean {
  for (const key of keys) {
    if (key.name === name) return key.default !== null;
  }
  return false;
}

/** One `* @sjon-exclusive-group …` content line per group, prefixed by
 *  `indent`. Shared by the form-level doc (`''`) and the per-variant
 *  branch doc (`'  '`) so both scopes spell the annotation identically.
 *  Mirrors Zig's `writeExclusiveGroupLines`. */
function exclusiveGroupLines(groups: readonly ModelExclusiveGroup[], indent: string): string {
  let out = '';
  for (const g of groups) {
    const card = g.cardinality === 'exactly_one' ? 'exactly-one' : 'at-most-one';
    const alts = g.alternatives.map((bundle) => bundle.join(' + ')).join(', ');
    out += `${indent} * @sjon-exclusive-group ${card} [${alts}]\n`;
  }
  return out;
}

function writeKey(key: ModelKey, indent: string, ctx: EmitContext): string {
  let out = '';
  const jsdoc = buildKeyJSDoc(key, indent);
  if (jsdoc) out += jsdoc;
  const optMark = key.optional ? '?' : '';
  out += `${indent}${escapeIdentifier(key.name)}${optMark}: ${writeShape(key.value, ctx)};\n`;
  return out;
}

/**
 * Emit a slot-local form as an inline anonymous object-literal type (no
 * `export interface NAME` header — locals have no global type name). Mirrors
 * `writeInlineLocalForm` in `src/SchemaExport/TsTypes.zig`: compact, single
 * line, `$ns` optional (locals are bare-invoked). A discriminated local emits
 * a parenthesised union of per-variant branches so TS narrows on the
 * discriminant brand, matching the JSON side's if/then reuse.
 */
function writeInlineLocalForm(form: ModelForm, ctx: EmitContext): string {
  const sortedKeys = sortKeys(form.keys);
  if (form.discriminator) {
    const disc = form.discriminator;
    const branches = disc.variants.map((v) =>
      writeInlineDiscriminatedBranch(form, disc, v.when, v.keys, v.exclusiveGroups, ctx),
    );
    // The residual branch, as in `writeDiscriminatedFormType`.
    const residual = residualMembers(form, disc);
    if (residual.length > 0) {
      branches.push(writeInlineDiscriminatedBranch(form, disc, residual, [], [], ctx));
    }
    let out = `(${branches.join(' | ')})`;
    // Form-level enforced groups intersect the parenthesised branch
    // union, exactly as the block-shaped discriminated emitter wraps its
    // own.
    for (const g of form.exclusiveGroups) {
      if (groupState(form, g) !== 'enforced') continue;
      out += ' & (' + writeGroupArmsInline(form.keys, g, ctx) + ')';
    }
    return out;
  }
  let out = `{ $form: "${form.name}"; $ns?: string;`;
  for (const k of sortedKeys) {
    if (isKeyGroupedEnforced(form.open, form.keys, form.exclusiveGroups, k.name)) continue;
    out += ` ${writeInlineLocalKey(k, ctx)}`;
  }
  switch (form.positional.kind) {
    case 'none':
      break;
    case 'any':
      out += ' $children?: unknown[];';
      break;
    case 'kind':
      out += ` $children?: Array<${writeShape(form.positional.shape, ctx)}>;`;
      break;
    default:
      assertNever(form.positional);
  }
  if (form.open) out += ' [key: string]: unknown;';
  out += ' }';
  // Enforced groups apply the same anonymous-base/intersection
  // construction inline; `&` binds tighter than `|`, so a slot union
  // member stays correctly scoped without extra parentheses.
  for (const g of form.exclusiveGroups) {
    if (groupState(form, g) !== 'enforced') continue;
    out += ' & (' + writeGroupArmsInline(form.keys, g, ctx) + ')';
  }
  return out;
}

/** One `{ … }` branch of an inline discriminated local's union — the
 *  one-line mirror of `writeDiscriminatedBranch`, including the
 *  variant-group arm intersection. */
function writeInlineDiscriminatedBranch(
  form: ModelForm,
  disc: ModelDiscriminator,
  when: readonly string[],
  overlay: readonly ModelKey[],
  groups: readonly ModelExclusiveGroup[],
  ctx: EmitContext,
): string {
  let out = `{ $form: "${form.name}"; $ns?: string;`;
  for (const k of sortKeys(form.keys)) {
    if (isKeyGroupedEnforced(form.open, form.keys, form.exclusiveGroups, k.name)) continue;
    out +=
      k.name === disc.keyName
        ? ` ${escapeIdentifier(k.name)}: ${whenBrand(when)};`
        : ` ${writeInlineLocalKey(k, ctx)}`;
  }
  for (const vk of sortKeys(overlay)) {
    if (isKeyGroupedEnforced(form.open, overlay, groups, vk.name)) continue;
    out += ` ${writeInlineLocalKey(vk, ctx)}`;
  }
  if (form.open) out += ' [key: string]: unknown;';
  out += ' }';
  for (const g of groups) {
    if (groupStateForScope(form.open, overlay, g) !== 'enforced') continue;
    out += ' & (' + writeGroupArmsInline(overlay, g, ctx) + ')';
  }
  return out;
}

/** Compact single-line key for an inline local-form literal: `name?: T;`. */
function writeInlineLocalKey(key: ModelKey, ctx: EmitContext): string {
  const optMark = key.optional ? '?' : '';
  return `${escapeIdentifier(key.name)}${optMark}: ${writeShape(key.value, ctx)};`;
}

/** Whether `key`'s slot renders a JSDoc block/line above the property —
 *  shared by `buildKeyJSDoc` and the multi-line arm shape decision.
 *  Mirrors `keyNeedsDoc` in `src/SchemaExport/TsTypes.zig`, unit
 *  metadata included: a unit-bearing key carries `@sjon-unit`. */
function keyNeedsDoc(key: ModelKey): boolean {
  if (key.description) return true;
  if (key.default && key.default.kind === 'expression') return true;
  if (numericBoundsOf(key.value)) return true;
  if (stringBoundsOf(key.value)) return true;
  if (key.requires.length > 0) return true;
  if (crossRefOf(key.value)) return true;
  if (unitOf(key.value)) return true;
  if (richMembersOf(key.value)) return true;
  return false;
}

function buildKeyJSDoc(key: ModelKey, indent: string): string {
  const lines: string[] = [];
  if (key.description) lines.push(key.description);
  if (key.default && key.default.kind === 'expression') {
    lines.push(`@default computed via \`${key.default.snapshot.head}\``);
  }
  const bounds = numericBoundsOf(key.value);
  if (bounds) {
    if (bounds.min)
      lines.push(`@minimum ${bounds.min.value}${bounds.exclusiveMin ? ' (exclusive)' : ''}`);
    if (bounds.max)
      lines.push(`@maximum ${bounds.max.value}${bounds.exclusiveMax ? ' (exclusive)' : ''}`);
    if (bounds.integer) lines.push('@integer true');
    // TS has no divisibility constraint, so this is JSDoc-only. (Tag
    // spelling follows this host's local convention — `@integer`, not
    // Zig's `@sjon-integer` — which these JSDoc lines already use.)
    if (bounds.multipleOf) lines.push(`@multiple-of ${bounds.multipleOf.value}`);
  }
  const sb = stringBoundsOf(key.value);
  if (sb) {
    if (sb.minLen != null) lines.push(`@minLength ${sb.minLen}`);
    if (sb.maxLen != null) lines.push(`@maxLength ${sb.maxLen}`);
    if (sb.pattern) lines.push(`@pattern ${sb.pattern}`);
    if (sb.format) lines.push(`@format ${sb.format}`);
  }
  if (key.requires.length > 0) {
    // Not expressible in a plain interface — it would need a discriminated
    // union over which keys are present. Tag matches the Zig exporter's
    // byte-for-byte, since the kit-xor golden is compared directly.
    lines.push(`@sjon-requires ${key.requires.join(', ')}`);
  }
  const cr = crossRefOf(key.value);
  if (cr) {
    // Prose names only what the route can carry: `name-key` and `acyclic`
    // are identity-only (the loader rejects the first beside a provider,
    // and cycle edges need per-name declaration sites extracted names
    // don't have). Mirrors `writeCrossRefDoc` in `TsTypes.zig`.
    const route =
      cr.provider === null
        ? `name-key=${cr.nameKey} acyclic=${cr.acyclic}`
        : `provider=${cr.provider} source-key=${cr.sourceKey}`;
    lines.push(
      `@sjon-cross-ref target=${cr.targets.join(' | ')} ${route}` +
        (cr.scopeForm ? ` scope-form=${cr.scopeForm}` : ''),
    );
  }
  const unit = unitOf(key.value);
  if (unit) {
    // Mirrors `writeUnitDoc` in `TsTypes.zig` byte for byte:
    // `@sjon-unit required=true allowed=[mm, cm, m]`.
    let unitLine = `@sjon-unit required=${unit.required ? 'true' : 'false'}`;
    if (unit.allowed.length > 0) {
      unitLine += ` allowed=[${unit.allowed.join(', ')}]`;
    }
    lines.push(unitLine);
  }
  const rich = richMembersOf(key.value);
  if (rich) {
    for (const m of rich) {
      if (m.deprecated) lines.push(`@deprecated ${m.deprecationMessage || m.name}`);
    }
  }
  if (lines.length === 0) return '';
  // Block form whenever any line is an `@`-annotation, single-line only for
  // a lone description — mirroring `TsTypes.zig`'s `use_block` rule. The
  // two emitters are byte-compared across the group-* / kit / kit-xor /
  // local-forms goldens (`:description` included — the loader reads it),
  // so the *shape* has to agree and not just the content. Continuation
  // lines carry `indent`, as Zig's do.
  const hasAnnotation = lines.some((l) => l.startsWith('@'));
  if (lines.length === 1 && !hasAnnotation) return `${indent}/** ${lines[0]} */\n`;
  return `${indent}/**\n` + lines.map((l) => `${indent} * ${l}`).join('\n') + `\n${indent} */\n`;
}

/** Every form name in the model, deduped by name, in declaration order —
 *  the unqualified-global enumeration a `form_locals` fallback offers
 *  beside its local arms. Mirrors Zig's `dedupeGlobalFormNames` (the
 *  `current_global_forms` threadlocal). */
function globalFormNames(model: Model): readonly string[] {
  const names: string[] = [];
  for (const p of model.plugins) {
    for (const f of p.forms) {
      if (!names.includes(f.name)) names.push(f.name);
    }
  }
  return names;
}

function writeShape(shape: ModelValueShape, ctx: EmitContext): string {
  switch (shape.kind) {
    case 'any':
      return 'unknown';
    case 'nil':
      return 'null';
    case 'boolean':
      return 'boolean';
    case 'number':
      return 'number';
    // A `:repr`-tagged number renders as its branded GPU alias
    // (`F32`…`F16`); a plain bounded number stays `number` (min/max aren't
    // expressible in a TS structural type).
    case 'number_bounded':
      return shape.bounds.repr ? reprTsAlias(shape.bounds.repr) : 'number';
    case 'number_i64':
    case 'number_u64':
      return 'bigint';
    case 'number_with_unit':
      return writeUnitTuple(shape.unit);
    case 'string':
    case 'string_with_bounds':
      return 'string';
    case 'symbol':
      return 'Symbol_';
    case 'symbol_members':
      return shape.members.map((n) => `Symbol_<"${n}">`).join(' | ');
    case 'symbol_members_rich':
      // A digit-leading member breaks the brand: a document writes `2d` as
      // a unit-bearing number, so its alternative is the `[magnitude,
      // unit]` tuple `number_with_unit` already uses. `Symbol_<"2d">` here
      // would make the `.d.ts` reject a document the validator accepts.
      return shape.members
        .map((m) =>
          m.numericSpelling !== undefined
            ? `readonly [${m.numericSpelling.magnitude}, "${m.numericSpelling.unit}"]`
            : `Symbol_<"${m.name}">`,
        )
        .join(' | ');
    case 'string_members':
    case 'string_members_rich': {
      const names =
        shape.kind === 'string_members' ? shape.members : shape.members.map((m) => m.name);
      return names.map((n) => `"${n}"`).join(' | ');
    }
    case 'date':
      return 'SjonDate';
    case 'time':
      return 'SjonTime';
    case 'keyword':
      return 'Keyword';
    case 'vector': {
      if (shape.vector.len != null && shape.vector.len <= 8) {
        return `readonly [${Array(shape.vector.len)
          .fill(writeShape(shape.vector.element, ctx))
          .join(', ')}]`;
      }
      return `Array<${writeShape(shape.vector.element, ctx)}>`;
    }
    case 'form_any':
      return '{ readonly $form: string }';
    case 'form_heads': {
      // A slot-local head has no global type to name, so it emits the same
      // inline object literal the `form_locals` arm emits — the local's
      // keys are what a consumer wants IntelliSense on.
      const branches = shape.heads.map((head) => {
        const body = refBody(head);
        if (body.kind === 'local') return writeInlineLocalForm(body.form, ctx);
        return head.plugin
          ? formTypeName(head.plugin, head.name)
          : `{ readonly $form: "${head.name}" }`;
      });
      return branches.length > 0 ? branches.join(' | ') : 'never';
    }
    case 'form_locals': {
      // Inline anonymous union of object literals (one per local form)
      // plus the additive global fallback. TS narrows on the `$form`
      // discriminant. Every fallback arm names a global head — none
      // spells `$form: string` — because excess-property checking fires
      // on fresh object literals only: an open arm admits every declared
      // local head the moment its value arrives through a variable, a
      // function parameter, or `JSON.parse`, and the slot's group stops
      // being enforced at compile time. The unqualified arms enumerate
      // the globals the slot's local heads do not shadow (a bare head
      // resolves local-first with shadowing, so a local name can never
      // reach a global); the qualified arms enumerate every global,
      // shadowed names included — a `$ns` head bypasses locals and
      // resolves against the plugin catalog, where a namespace naming
      // no plugin or no such form is `unknown_form`. The `$ns` spelling
      // itself stays runtime-checked, the same one-way acceptance the
      // fallback's key enforcement has always had.
      // Mirrors the Zig `form_locals` arm in `TsTypes.zig`.
      const branches = shape.forms.map((lf) => writeInlineLocalForm(lf, ctx));
      for (const name of globalFormNames(ctx.model)) {
        if (shape.forms.some((lf) => lf.name === name)) continue;
        branches.push(`{ readonly $form: "${name}" }`);
      }
      for (const name of globalFormNames(ctx.model)) {
        branches.push(`{ readonly $form: "${name}"; readonly $ns: string }`);
      }
      return branches.join(' | ');
    }
    case 'expr':
      return 'SjonExpr';
    case 'cross_ref':
      // A group is a union of brands, one per target — the honest TS
      // reading of "this name may come from either form".
      return shape.crossRef.targets.map((t) => `CrossRef<"${t}">`).join(' | ');
    case 'union_of':
      return shape.alternatives.map((a) => writeShape(a.shape, ctx)).join(' | ');
    case 'unresolved_named':
      return `unknown /* unresolved: ${shape.name} */`;
    default:
      return assertNever(shape);
  }
}

function writeUnitTuple(unit: ModelUnitShape): string {
  // `readonly` matches the Zig emitter (a unit value round-trips through
  // the bridge as a fixed pair; the golden fixtures byte-compare it).
  if (unit.allowed.length > 0) {
    return unit.allowed.map((u) => `readonly [number, "${u}"]`).join(' | ');
  }
  return 'readonly [number, string]';
}

function writeBarrel(plugin: ModelPlugin): string {
  if (plugin.forms.length === 0) return '';
  const formNames = plugin.forms.map((f) => formTypeName(plugin.name, f.name));
  return `export type Sjon${pascalCase(plugin.name)} =\n  | ${formNames.join('\n  | ')};\n\n`;
}

// ---------------------------------------------------------------------------
// JSDoc-axis helpers
// ---------------------------------------------------------------------------

function numericBoundsOf(shape: ModelValueShape): ModelNumericBounds | null {
  if (shape.kind === 'number_bounded') return shape.bounds;
  if (shape.kind === 'number_with_unit') return shape.unit.bounds;
  return null;
}

function stringBoundsOf(shape: ModelValueShape): ModelStringBounds | null {
  if (shape.kind === 'string_with_bounds') return shape.bounds;
  return null;
}

function crossRefOf(shape: ModelValueShape): ModelCrossRef | null {
  if (shape.kind === 'cross_ref') return shape.crossRef;
  return null;
}

function unitOf(shape: ModelValueShape): ModelUnitShape | null {
  if (shape.kind === 'number_with_unit') return shape.unit;
  return null;
}

function richMembersOf(shape: ModelValueShape): readonly ModelMember[] | null {
  if (shape.kind === 'symbol_members_rich' || shape.kind === 'string_members_rich') {
    return shape.members;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Naming
// ---------------------------------------------------------------------------

function formTypeName(plugin: string, form: string): string {
  return `${pascalCase(plugin)}_${pascalCase(form)}`;
}

function pascalCase(s: string): string {
  return s
    .split(/[-_/]/)
    .map((seg) => (seg.length === 0 ? '' : seg[0]!.toUpperCase() + seg.slice(1)))
    .join('');
}

const TS_RESERVED = new Set([
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'debugger',
  'default',
  'delete',
  'do',
  'else',
  'enum',
  'export',
  'extends',
  'false',
  'finally',
  'for',
  'function',
  'if',
  'import',
  'in',
  'instanceof',
  'new',
  'null',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'typeof',
  'var',
  'void',
  'while',
  'with',
  'yield',
]);

function escapeIdentifier(name: string): string {
  if (TS_RESERVED.has(name)) return `"${name}"`;
  if (/[^A-Za-z0-9_$]/.test(name)) return `"${name}"`;
  return name;
}
