// Serializer — builder IR → canonical `(plugin …)` manifest text.
//
// This text is the universal contract: every SJON host (WASM/Zig, the
// native TS validator, the Rust host) consumes the same manifest grammar
// (`hosts/typescript-parity/src/loader.ts` is the reference reader). The
// builder is just sugar in front of it.
//
// Hoisting rule: SJON has no inline refinements — bounds, enums, typed
// vectors, and cross-refs are all *named* `(value-kind …)` declarations
// referenced from a key's `:type`. So any leaf that isn't a bare builtin
// is hoisted into a generated value-kind, deduped by structural name
// across the whole plugin. `s.kind("score", …)` / `s.slug()` supply the
// name; anonymous leaves get a stable structural one.

import type {
  CrossRefIR,
  CrossRefProviderDef,
  FormDef,
  NamedKindDef,
  NodeDef,
  NumericBoundsIR,
  PluginDef,
  ShapeIR,
  StringBoundsIR,
} from './shape.ts';
import { resolveFormDef } from './shape.ts';
import { assertNever } from './internal.ts';
import { serializeValue } from './value.ts';
import type { SjonValue } from './value.ts';

/** A value-kind queued for emission, keyed by its (unique) name. */
interface HoistedKind {
  readonly name: string;
  readonly shape: ShapeIR;
  readonly description?: string;
}

class KindRegistry {
  private readonly byName = new Map<string, HoistedKind>();
  private readonly order: string[] = [];
  // Nested-form sub-registry: the inner `(form …)` declarations a typed
  // `s.formOf(...)` slot pulls in. Kept separate from value-kinds because they
  // emit as `(form …)` blocks, not `(value-kind …)`. Deduped by head (heads are
  // unique within a plugin), never by deep-stringifying a possibly-large def.
  private readonly formsByHead = new Map<string, FormDef>();
  private readonly formOrder: string[] = [];
  // Heads already emitted as top-level forms — not re-emitted as nested.
  private readonly seededForms = new Set<string>();

  /** Resolve `def`'s shape to a `:type` token, hoisting a value-kind if needed. */
  typeToken(def: NodeDef): string {
    return this.shapeToken(
      def.shape,
      def.suggestedKind,
      def.description,
      def.explicitKind === true,
    );
  }

  /** Resolve a bare shape (used for vector elements, which carry no NodeDef). */
  shapeToken(shape: ShapeIR, suggested?: string, description?: string, explicit = false): string {
    switch (shape.kind) {
      case 'any':
      case 'nil':
      case 'boolean':
      case 'symbol':
      case 'expr':
        return shape.kind;
      case 'form_any':
        return 'form';
      case 'number':
        if (!shape.bounds) return 'number';
        return this.register(shape, suggested ?? generatedName(shape), description, explicit);
      case 'string':
        if (!shape.bounds) return 'string';
        return this.register(shape, suggested ?? generatedName(shape), description, explicit);
      case 'vector':
        if (shape.element.kind === 'any' && shape.len === undefined) return 'vector';
        // A vector-of-form must have its element form value-kind (+ inner form)
        // registered NOW, during the `serializeForm` typeToken pass, so it lands
        // in `assemble`'s value-kind snapshot. `elementToken` resolves the
        // `:element` ref to the same `${head}-form` name this produces.
        if (shape.element.kind === 'form') this.shapeToken(shape.element);
        return this.register(shape, suggested ?? generatedName(shape), description, explicit);
      case 'form':
        // Queue the inner `(form …)` block, then hoist a value-kind that pins
        // the slot to that form's head. Named `${head}-form` unless `s.kind`
        // gave an explicit name (direct keys only — `s.vector` drops the hint).
        this.declareForm(resolveFormDef(shape));
        return this.register(
          shape,
          suggested ?? `${resolveFormDef(shape).head}-form`,
          description,
          explicit,
        );
      case 'symbol_members':
      case 'string_members':
      case 'cross_ref':
        return this.register(shape, suggested ?? generatedName(shape), description, explicit);
      default:
        return assertNever(shape);
    }
  }

  private register(
    shape: ShapeIR,
    name: string,
    description: string | undefined,
    explicit: boolean,
  ): string {
    const existing = this.byName.get(name);
    if (existing) {
      if (!shapesEqual(existing.shape, shape)) {
        if (explicit) {
          throw new Error(
            `SJON schema: value-kind name "${name}" is reused for two different shapes.`,
          );
        }
        // Anonymous collision (rare hash clash): disambiguate by suffix.
        const alt = `${name}-${this.order.length}`;
        return this.register(shape, alt, description, explicit);
      }
      return name;
    }
    const hoisted: HoistedKind =
      description !== undefined ? { name, shape, description } : { name, shape };
    this.byName.set(name, hoisted);
    this.order.push(name);
    return name;
  }

  /** Pre-register an explicitly-named kind (`s.kind`) so it emits even if unreferenced. */
  declareNamed(named: NamedKindDef): void {
    this.shapeToken(named.def.shape, named.name, named.def.description, true);
  }

  emitted(): readonly HoistedKind[] {
    return this.order.map((n) => this.byName.get(n)!);
  }

  /**
   * Queue an inner form for `(form …)` emission and eagerly hoist any
   * value-kinds / deeper nested forms its keys reference, so everything is
   * registered before `assemble` snapshots. Deduped by head; a head already
   * emitted top-level (seeded) is skipped. The head guard also makes a form
   * cycle terminate (cycles are out of scope on the type side, defensive here).
   */
  declareForm(form: FormDef): void {
    if (this.formsByHead.has(form.head) || this.seededForms.has(form.head)) return;
    this.formsByHead.set(form.head, form);
    this.formOrder.push(form.head);
    for (const key of form.keys) this.typeToken(key.def);
  }

  /** Mark a head as emitted top-level, so it is not also emitted as a nested form. */
  seedForm(head: string): void {
    this.seededForms.add(head);
  }

  /** The queued inner forms, in declaration order. */
  emittedForms(): readonly FormDef[] {
    return this.formOrder.map((h) => this.formsByHead.get(h)!);
  }
}

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

/** Serialize a multi-form plugin to canonical manifest text. */
export function serializePlugin(plugin: PluginDef): string {
  const registry = new KindRegistry();
  for (const named of plugin.namedKinds) registry.declareNamed(named);
  // Seed every top-level head so a form that is *also* used as a nested
  // `s.formOf` element isn't emitted twice (once top-level, once hoisted).
  for (const f of plugin.forms) registry.seedForm(f.head);
  const formBlocks = plugin.forms.map((f) => serializeForm(f, registry));
  return assemble(
    plugin.name,
    plugin.version,
    plugin.description,
    registry,
    formBlocks,
    plugin.crossRefProviders,
  );
}

/** Serialize a single form as a self-contained one-form plugin (its `$ns`). */
export function serializeFormAsPlugin(form: FormDef): string {
  const registry = new KindRegistry();
  // Seed the top-level head so a *self-referential* form (a key reaching back to
  // `form` via `s.formOf(() => Self)`) isn't also emitted as a hoisted inner
  // form — exactly the dedup `serializePlugin` does for its form set.
  registry.seedForm(form.head);
  const block = serializeForm(form, registry);
  return assemble(form.ns, '1.0.0', undefined, registry, [block]);
}

function assemble(
  name: string,
  version: string,
  description: string | undefined,
  registry: KindRegistry,
  formBlocks: readonly string[],
  providers: readonly CrossRefProviderDef[] = [],
): string {
  const lines: string[] = [];
  const header = `(plugin :name ${atom(name)} :version ${quote(version)}`;
  lines.push(description ? `${header} :description ${quote(description)}` : header);
  // Providers first: a `(cross-ref :provider …)` below reads better when
  // the name it cites has already been introduced. Resolution is by name,
  // so order is free — this is for the human.
  for (const p of providers) lines.push(indent(crossRefProvider(p)));
  for (const kind of registry.emitted()) lines.push(indent(serializeValueKind(kind)));
  // Inner `(form …)` blocks pulled in by nested `s.formOf` slots. Re-serializing
  // here only re-hits dedup (declareForm already hoisted their value-kinds), so
  // the snapshot above is complete. Validator resolves by name → order is free.
  for (const inner of registry.emittedForms()) lines.push(indent(serializeForm(inner, registry)));
  for (const block of formBlocks) lines.push(indent(block));
  // Close the plugin form on the last line.
  return `${lines.join('\n\n')})\n`;
}

function serializeForm(form: FormDef, registry: KindRegistry): string {
  const head = `(form :name ${atom(form.head)}`;
  const headLine = form.description ? `${head} :description ${quote(form.description)}` : head;
  const keyLines = form.keys.map((k) => {
    const type = registry.typeToken(k.def);
    let line = `(key :name ${atom(k.name)} :type ${atom(type)} :optional ${k.def.isOptional ? 'true' : 'false'}`;
    // A `.default(v)` emits `:default <literal>`; the value drives cross-host
    // default behaviour (Zig's effectiveOptional, the exporters' @default).
    if (k.def.default !== undefined)
      line += ` :default ${serializeValue(k.def.default as SjonValue)}`;
    return indent(`${line})`);
  });
  if (keyLines.length === 0) return `${headLine})`;
  return `${headLine}\n${keyLines.join('\n')})`;
}

function serializeValueKind(kind: HoistedKind): string {
  const parts: string[] = [`(value-kind :name ${atom(kind.name)}`];
  if (kind.description !== undefined) parts.push(`:description ${quote(kind.description)}`);
  parts.push(`:underlying ${underlyingOf(kind.shape)}`);
  parts.push(refinementOf(kind.shape));
  return `${parts.filter((p) => p.length > 0).join(' ')})`;
}

function underlyingOf(shape: ShapeIR): string {
  switch (shape.kind) {
    case 'number':
      return 'number';
    case 'string':
    case 'string_members':
      return 'string';
    case 'symbol_members':
    case 'cross_ref':
      return 'symbol';
    case 'vector':
      return 'vector';
    case 'form':
      return 'form';
    // Builtins never hoist into a value-kind (`shapeToken` returns them
    // inline), so they never reach here; keep the prior `symbol` fallback as
    // explicit arms so a new ShapeIR variant trips `assertNever` instead.
    case 'any':
    case 'nil':
    case 'boolean':
    case 'symbol':
    case 'expr':
    case 'form_any':
      return 'symbol';
    default:
      return assertNever(shape);
  }
}

function refinementOf(shape: ShapeIR): string {
  switch (shape.kind) {
    case 'number':
      return shape.bounds ? `:numeric ${numericBounds(shape.bounds)}` : '';
    case 'string':
      return shape.bounds ? `:string-bounds ${stringBounds(shape.bounds)}` : '';
    case 'symbol_members':
    case 'string_members':
      return `:members (member-set :values [${shape.members.map(atom).join(' ')}])`;
    case 'vector': {
      // Vector element → its `:type` token: a builtin inline, or a nested
      // `s.formOf` element's `${head}-form` value-kind. Refined/enum elements
      // still aren't expressible inline (lift to a named `s.kind`).
      const element = elementToken(shape.element);
      const len = shape.len !== undefined ? ` :len ${shape.len}` : '';
      return `:vector (vector-shape :element ${element}${len})`;
    }
    case 'form':
      return `:heads (head-set :names [${atom(resolveFormDef(shape).head)}])`;
    case 'cross_ref':
      return `:cross-ref ${crossRef(shape.crossRef)}`;
    // Builtins carry no refinement axis (and never hoist) — emit nothing,
    // explicitly, so a new ShapeIR variant trips `assertNever`.
    case 'any':
    case 'nil':
    case 'boolean':
    case 'symbol':
    case 'expr':
    case 'form_any':
      return '';
    default:
      return assertNever(shape);
  }
}

function numericBounds(b: NumericBoundsIR): string {
  const parts: string[] = ['(numeric-bounds'];
  if (b.min !== undefined) parts.push(`:min ${String(b.min)}`);
  if (b.max !== undefined) parts.push(`:max ${String(b.max)}`);
  if (b.exclusiveMin) parts.push(':exclusive-min true');
  if (b.exclusiveMax) parts.push(':exclusive-max true');
  if (b.integer) parts.push(':integer true');
  return `${parts.join(' ')})`;
}

function stringBounds(b: StringBoundsIR): string {
  const parts: string[] = ['(string-bounds'];
  if (b.minLen !== undefined) parts.push(`:min-len ${b.minLen}`);
  if (b.maxLen !== undefined) parts.push(`:max-len ${b.maxLen}`);
  if (b.pattern !== undefined) parts.push(`:pattern ${quote(b.pattern)}`);
  if (b.format !== undefined) parts.push(`:format ${atom(b.format)}`);
  return `${parts.join(' ')})`;
}

function crossRef(cr: CrossRefIR): string {
  const parts: string[] = [`(cross-ref :target ${atom(cr.target)}`];
  if (cr.nameKey !== undefined) parts.push(`:name-key ${atom(cr.nameKey)}`);
  if (cr.acyclic) parts.push(':acyclic true');
  if (cr.scope !== undefined) parts.push(`:scope ${atom(cr.scope)}`);
  if (cr.provider !== undefined) parts.push(`:provider ${atom(cr.provider)}`);
  if (cr.sourceKey !== undefined) parts.push(`:source-key ${atom(cr.sourceKey)}`);
  return `${parts.join(' ')})`;
}

function crossRefProvider(p: CrossRefProviderDef): string {
  const parts: string[] = [`(cross-ref-provider :name ${atom(p.name)}`];
  if (p.description !== undefined) parts.push(`:description ${quote(p.description)}`);
  return `${parts.join(' ')})`;
}

// ---------------------------------------------------------------------------
// Naming + atom helpers
// ---------------------------------------------------------------------------

/**
 * A vector element's `:type` token: builtins inline, a nested `s.formOf`
 * element resolved to its deterministic `${head}-form` value-kind (registered
 * eagerly in `shapeToken`'s vector arm, so the name always resolves).
 */
function elementToken(shape: ShapeIR): string {
  if (shape.kind === 'form') return `${resolveFormDef(shape).head}-form`;
  return builtinElementToken(shape);
}

/** A vector element's `:type` token — restricted to builtins in this version. */
function builtinElementToken(shape: ShapeIR): string {
  switch (shape.kind) {
    case 'any':
    case 'nil':
    case 'boolean':
    case 'symbol':
    case 'expr':
      return shape.kind;
    case 'form_any':
      return 'form';
    case 'number':
      if (!shape.bounds) return 'number';
      break;
    case 'string':
      if (!shape.bounds) return 'string';
      break;
    case 'vector':
      if (shape.element.kind === 'any' && shape.len === undefined) return 'vector';
      break;
    // Composite / refined elements aren't expressible inline — fall through to
    // the throw below. Listed explicitly (rather than a catch-all `default`) so
    // a new ShapeIR variant trips `assertNever` instead of silently throwing.
    case 'symbol_members':
    case 'string_members':
    case 'cross_ref':
    case 'form':
      break;
    default:
      return assertNever(shape);
  }
  throw new Error(
    `SJON schema: vector elements must be builtin types in this version (got "${shape.kind}" with refinements). ` +
      'Lift the element to a named `s.kind(...)` and use a form/cross-ref instead.',
  );
}

const SYMBOL_RE = /^[A-Za-z_][\w-]*$/;

/** Emit a name/token as a bare symbol when valid, else a quoted string. */
function atom(text: string): string {
  return SYMBOL_RE.test(text) ? text : quote(text);
}

function quote(text: string): string {
  return JSON.stringify(text);
}

/** A stable, readable structural name for an anonymous hoisted leaf. */
function generatedName(shape: ShapeIR): string {
  switch (shape.kind) {
    case 'number': {
      const b = shape.bounds ?? {};
      const segs = ['num'];
      if (b.min !== undefined) segs.push(`min${slugNum(b.min)}`);
      if (b.max !== undefined) segs.push(`max${slugNum(b.max)}`);
      if (b.exclusiveMin) segs.push('xmin');
      if (b.exclusiveMax) segs.push('xmax');
      if (b.integer) segs.push('int');
      return segs.join('-');
    }
    case 'string': {
      const b = shape.bounds ?? {};
      const segs = ['str'];
      if (b.format !== undefined) segs.push(`fmt-${slugText(b.format)}`);
      if (b.minLen !== undefined) segs.push(`min${b.minLen}`);
      if (b.maxLen !== undefined) segs.push(`max${b.maxLen}`);
      if (b.pattern !== undefined) segs.push(`pat${hash(b.pattern)}`);
      return segs.join('-');
    }
    case 'symbol_members':
      return `sym-${shape.members.map(slugText).join('-') || hash(shape.members.join(','))}`;
    case 'string_members':
      return `enum-${shape.members.map(slugText).join('-') || hash(shape.members.join(','))}`;
    case 'vector':
      return `vec-${slugText(elementToken(shape.element))}${shape.len !== undefined ? `-len${shape.len}` : ''}`;
    case 'form':
      return `${resolveFormDef(shape).head}-form`;
    case 'cross_ref':
      return `ref-${slugText(shape.crossRef.target)}`;
    // Builtins never hoist, so they never need a generated name; keep the prior
    // structural fallback explicit so a new ShapeIR variant trips `assertNever`.
    case 'any':
    case 'nil':
    case 'boolean':
    case 'symbol':
    case 'expr':
    case 'form_any':
      return `kind-${hash(shape.kind)}`;
    default:
      return assertNever(shape);
  }
}

function slugNum(value: number): string {
  return String(value).replace(/[^0-9]/g, (c) => (c === '-' ? 'n' : c === '.' ? 'p' : ''));
}

function slugText(text: string): string {
  const cleaned = text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return cleaned.length > 0 ? cleaned : hash(text);
}

/** Small deterministic FNV-1a → 6 hex chars. For names only, not security. */
function hash(text: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16).padStart(8, '0').slice(0, 6);
}

function indent(block: string): string {
  return block
    .split('\n')
    .map((line) => `  ${line}`)
    .join('\n');
}

// ---------------------------------------------------------------------------
// Structural equality for dedup
// ---------------------------------------------------------------------------

function shapesEqual(a: ShapeIR, b: ShapeIR): boolean {
  if (a.kind !== b.kind) return false;
  // Forms are identified by head (unique per plugin) — never deep-stringify a
  // FormDef, which could be large or (defensively) self-referential.
  if (a.kind === 'form')
    return resolveFormDef(a).head === resolveFormDef(b as Extract<ShapeIR, { kind: 'form' }>).head;
  if (a.kind === 'vector') {
    const bv = b as Extract<ShapeIR, { kind: 'vector' }>;
    return a.len === bv.len && shapesEqual(a.element, bv.element);
  }
  return JSON.stringify(a) === JSON.stringify(b);
}
