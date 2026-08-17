// Builder runtime — the fluent `s` factory.
//
// Each factory returns a node whose phantom `_out`/`_in` types
// (`infer.ts`) carry the inferred shape and whose `_def`
// (`shape.ts`) carries the serialization IR. Nodes are immutable:
// `.optional()` / refinements return fresh nodes. Forms additionally
// expose `.parse` / `.manifest` etc., wired to the registered backend
// (`backend.ts`) over the serialized manifest (`serialize.ts`).

import type {
  AnyNode,
  CrossRef,
  DefaultedNode,
  FixedTuple,
  FormDocument,
  FormFieldNode,
  FormInput,
  FormNode,
  MemberSymbol,
  NumberNode,
  Node,
  OptionalNode,
  PluginNode,
  ShapeRecord,
  SjonExpr,
  StringNode,
  Symbol_,
  VectorNode,
} from './infer.ts';
import type {
  CrossRefIR,
  CrossRefProviderDef,
  FormDef,
  FormKeyDef,
  NamedKindDef,
  NodeDef,
  NumericBoundsIR,
  PluginDef,
  ShapeIR,
  StringBoundsIR,
} from './shape.ts';
import { resolveFormDef } from './shape.ts';
import { assertNever, canonicalMemberName, isFormObject } from './internal.ts';
import {
  type ParseOptions,
  type SafeEditResult,
  type SafeParseResult,
  type ToDtsOptions,
  type ValidateOutcome,
  applyAll,
  applyOne,
  SjonValidationError,
  requireBackend,
  requireEditBackend,
  runParse,
  runParseValue,
  safeApplyAll,
  safeApplyOne,
  useBackend,
} from './backend.ts';
import { diffToActions, replace } from './edit.ts';
import type { EditAction, EditPath } from './edit.ts';
import { serializeFormAsPlugin, serializePlugin } from './serialize.ts';
import { serializeValue } from './value.ts';
import type { SjonValue } from './value.ts';

// ---------------------------------------------------------------------------
// Generic leaf node
// ---------------------------------------------------------------------------

function leaf<Out, In = Out>(def: NodeDef): Node<Out, In> {
  const node = {
    _def: def,
    optional(): OptionalNode<Out, In> {
      return leaf<Out, In>({ ...def, isOptional: true }) as OptionalNode<Out, In>;
    },
    default(value: In | SjonExpr<Out>): DefaultedNode<Out, In> {
      return leaf<Out, In>({ ...def, default: value }) as DefaultedNode<Out, In>;
    },
    describe(description: string): Node<Out, In> {
      return leaf<Out, In>({ ...def, description });
    },
  };
  return node as unknown as Node<Out, In>;
}

// ---------------------------------------------------------------------------
// Number node (numeric refinements)
// ---------------------------------------------------------------------------

function numberNode(def: NodeDef): NumberNode {
  const current: NumericBoundsIR =
    def.shape.kind === 'number' && def.shape.bounds ? def.shape.bounds : {};
  const withBounds = (patch: NumericBoundsIR): NumberNode =>
    numberNode({ ...def, shape: { kind: 'number', bounds: { ...current, ...patch } } });
  const node = {
    _def: def,
    optional: () => numberNode({ ...def, isOptional: true }),
    default: (value: number) => numberNode({ ...def, default: value }),
    describe: (description: string) => numberNode({ ...def, description }),
    min: (value: number) => withBounds({ min: value }),
    max: (value: number) => withBounds({ max: value }),
    gt: (value: number) => withBounds({ min: value, exclusiveMin: true }),
    lt: (value: number) => withBounds({ max: value, exclusiveMax: true }),
    int: () => withBounds({ integer: true }),
    multipleOf: (divisor: number) => {
      // The loader refuses a non-positive divisor (it would divide by zero,
      // and a negative one is both redundant and unexportable — JSON Schema
      // requires `multipleOf > 0`). Refusing here names the call site.
      if (!(divisor > 0)) {
        throw new Error(
          `SJON schema: multipleOf(${divisor}) needs a positive divisor — zero has no multiples to check, and a negative divisor accepts exactly what its magnitude accepts.`,
        );
      }
      return withBounds({ multipleOf: divisor });
    },
  };
  return node as unknown as NumberNode;
}

// ---------------------------------------------------------------------------
// String node (length / pattern / format refinements)
// ---------------------------------------------------------------------------

function stringNode(def: NodeDef): StringNode {
  const current: StringBoundsIR =
    def.shape.kind === 'string' && def.shape.bounds ? def.shape.bounds : {};
  const withBounds = (patch: StringBoundsIR): StringNode =>
    stringNode({ ...def, shape: { kind: 'string', bounds: { ...current, ...patch } } });
  const node = {
    _def: def,
    optional: () => stringNode({ ...def, isOptional: true }),
    default: (value: string) => stringNode({ ...def, default: value }),
    describe: (description: string) => stringNode({ ...def, description }),
    minLen: (value: number) => withBounds({ minLen: value }),
    maxLen: (value: number) => withBounds({ maxLen: value }),
    pattern: (regex: string) => withBounds({ pattern: regex }),
    format: (name: string) => withBounds({ format: name }),
  };
  return node as unknown as StringNode;
}

function stringPreset(bounds: StringBoundsIR, suggestedKind: string): StringNode {
  return stringNode({ shape: { kind: 'string', bounds }, isOptional: false, suggestedKind });
}

// ---------------------------------------------------------------------------
// Form node
// ---------------------------------------------------------------------------

function buildFormDef(head: string, shape: ShapeRecord, ns: string, description?: string): FormDef {
  const keys: FormKeyDef[] = Object.keys(shape).map((name) => ({
    name,
    def: (shape[name] as AnyNode)._def,
  }));
  const base: FormDef = {
    head,
    ns,
    open: false,
    positional: { kind: 'none' },
    keys,
  };
  return description !== undefined ? { ...base, description } : base;
}

/**
 * Construct a conformant form value from a `FormDef` + typed input: stamp the
 * schema's `$form`/`$ns` (always — smuggled tags in the input are ignored),
 * copy each declared key through `materialize` (which recurses into nested
 * forms / vectors-of-forms), fill declared defaults for omitted defaulted keys,
 * and omit absent optionals. Module-level + def-driven so it recurses to any
 * depth without a registry. Backend-free.
 */
function createFromDef(def: FormDef, input: unknown): Record<string, unknown> {
  const out: Record<string, unknown> = { $form: def.head, $ns: def.ns };
  const fields = (input ?? {}) as Record<string, unknown>;
  for (const key of def.keys) {
    const provided = fields[key.name];
    if (provided !== undefined) {
      out[key.name] = materialize(key.def.shape, provided);
    } else if (key.def.default !== undefined) {
      // Fill the declared default, deep-cloned so callers can't mutate the
      // schema's value. A nested-form default is itself a constructed FormOut;
      // an expression default is plain data. Either way clone, don't re-build.
      out[key.name] = structuredClone(key.def.default);
    }
  }
  return out;
}

/**
 * Resolve one provided field value against its declared shape. A nested form
 * recurses through `createFromDef` (re-stamping inner tags + filling inner
 * defaults — idempotent if the value was already `Inner.create`d); a
 * vector-of-forms maps each element the same way; everything else is identity
 * (a leaf, or a primitive vector — no regression from the prior flat copy).
 */
function materialize(shape: ShapeIR, value: unknown): unknown {
  if (shape.kind === 'form') return createFromDef(resolveFormDef(shape), value);
  if (shape.kind === 'vector' && shape.element.kind === 'form' && Array.isArray(value)) {
    const elementForm = resolveFormDef(shape.element);
    return value.map((el) => createFromDef(elementForm, el));
  }
  return value;
}

// ---------------------------------------------------------------------------
// Edit-method runtime helpers (shared by every FormNode's setKey/removeKey/…)
// ---------------------------------------------------------------------------

/**
 * Split a typed edit path into the engine's parent-path + terminal key: the
 * engine's `set_keyword`/`remove_keyword` address a parent form plus a separate
 * key, but the typed API puts the key last in the path. A bare-key call passes
 * a string, normalized to a one-element path by the caller.
 */
function splitTerminal(full: EditPath): { readonly path: EditPath; readonly key: string } {
  const key = full[full.length - 1];
  if (typeof key !== 'string') {
    throw new Error('SJON schema: a setKey/removeKey path must end in a string key.');
  }
  return { path: full.slice(0, -1), key };
}

/** Project `source` and pull out the top-level form object the differ compares against. */
function currentFormJson(json: unknown): SjonValue {
  if (Array.isArray(json)) {
    const form = json.find(isFormObject);
    return (form ?? json[0] ?? {}) as SjonValue;
  }
  return (json ?? {}) as SjonValue;
}

function formNode<NS extends string, Head extends string, Sh extends ShapeRecord>(
  def: FormDef,
): FormNode<NS, Head, Sh> {
  type Out = FormNode<NS, Head, Sh>['_out'];
  const manifest = (): string => serializeFormAsPlugin(def);
  // Construct a conformant form value: delegate to the recursive, def-driven
  // `createFromDef` so nested forms / vectors-of-forms are stamped + filled at
  // every depth. Backend-free.
  const create = (input: FormInput<Sh>): Out => createFromDef(def, input) as Out;
  const node = {
    _def: def,
    describe: (description: string) => formNode<NS, Head, Sh>({ ...def, description }),
    create,
    toSjon: (input: FormInput<Sh>): string => serializeValue(create(input) as SjonValue),
    toCanonicalSjon: (input: FormInput<Sh>, options?: ParseOptions): string => {
      const backend = requireBackend(options?.backend);
      if (!backend.fromValue) {
        throw new Error(
          'SJON schema: backend has no `fromValue` — `.toCanonicalSjon()` is unavailable. Use `.toSjon()` for a backend-free path.',
        );
      }
      return backend.fromValue(create(input));
    },
    manifest,
    toDts: (options?: ToDtsOptions): string => {
      const backend = requireBackend(options?.backend);
      if (!backend.exportSchema) {
        throw new Error('SJON schema: backend has no `exportSchema` — `.toDts()` is unavailable.');
      }
      return backend.exportSchema(manifest()).tsTypes ?? '';
    },
    validate: (source: string, options?: ParseOptions): ValidateOutcome =>
      requireBackend(options?.backend).validate(`${manifest()}\n\n${source}`),
    parse: (source: string, options?: ParseOptions): Out => {
      const result = runParse<Out>(
        manifest(),
        source,
        def.ns,
        def.head,
        requireBackend(options?.backend),
      );
      if (!result.success) throw result.error;
      return result.data;
    },
    safeParse: (source: string, options?: ParseOptions): SafeParseResult<Out> =>
      runParse<Out>(manifest(), source, def.ns, def.head, requireBackend(options?.backend)),
    parseValue: (value: Out, options?: ParseOptions): Out => {
      const result = runParseValue<Out>(manifest(), value, requireBackend(options?.backend));
      if (!result.success) throw result.error;
      return result.data;
    },
    safeParseValue: (value: Out, options?: ParseOptions): SafeParseResult<Out> =>
      runParseValue<Out>(manifest(), value, requireBackend(options?.backend)),
    // --- Edit / write-back (typed surface declared on FormNode; impl is loose
    // because the node is cast to the interface at the end of formNode) ---
    applyEdit: (source: string, action: EditAction, options?: ParseOptions): string =>
      applyOne(source, action, requireEditBackend(options?.backend)),
    setKey: (
      source: string,
      pathOrKey: EditPath | string,
      value: SjonValue,
      options?: ParseOptions,
    ): string => {
      const { path, key } = splitTerminal(typeof pathOrKey === 'string' ? [pathOrKey] : pathOrKey);
      return applyOne(
        source,
        { op: 'set_keyword', path, key, value },
        requireEditBackend(options?.backend),
      );
    },
    removeKey: (source: string, pathOrKey: EditPath | string, options?: ParseOptions): string => {
      const { path, key } = splitTerminal(typeof pathOrKey === 'string' ? [pathOrKey] : pathOrKey);
      return applyOne(
        source,
        { op: 'remove_keyword', path, key },
        requireEditBackend(options?.backend),
      );
    },
    replaceAt: (source: string, path: EditPath, value: SjonValue, options?: ParseOptions): string =>
      applyOne(source, replace(path, value), requireEditBackend(options?.backend)),
    patch: (
      source: string,
      partial: Readonly<Record<string, SjonValue | undefined>>,
      options?: ParseOptions,
    ): string => {
      const backend = requireEditBackend(options?.backend);
      if (!backend.toJson) {
        throw new Error(
          'SJON schema: `.patch()` needs `toJson` to read the current document — use a WASM backend.',
        );
      }
      return applyAll(
        source,
        diffToActions(currentFormJson(backend.toJson(source)), partial),
        backend,
      );
    },
    safeApplyEdit: (source: string, action: EditAction, options?: ParseOptions): SafeEditResult =>
      safeApplyOne(source, action, requireEditBackend(options?.backend)),
    safePatch: (
      source: string,
      partial: Readonly<Record<string, SjonValue | undefined>>,
      options?: ParseOptions,
    ): SafeEditResult => {
      const backend = requireEditBackend(options?.backend);
      if (!backend.toJson) {
        throw new Error(
          'SJON schema: `.safePatch()` needs `toJson` to read the current document — use a WASM backend.',
        );
      }
      return safeApplyAll(
        source,
        diffToActions(currentFormJson(backend.toJson(source)), partial),
        backend,
      );
    },
    open: (source: string, options?: ParseOptions): FormDocument<NS, Head, Sh> => {
      const backend = requireEditBackend(options?.backend);
      if (!backend.toJson) {
        throw new Error(
          'SJON schema: `.open()` needs `toJson` to read the initial value — use a WASM backend.',
        );
      }
      const toJson = backend.toJson;
      const actions: EditAction[] = [];
      // `memo` is the current value preview: top-level set/remove update it
      // eagerly (O(1), no re-parse); a deep/positional edit nulls it so the
      // next `.value` re-derives by folding the queue through the engine.
      let memo: Record<string, unknown> | null = currentFormJson(toJson(source)) as Record<
        string,
        unknown
      >;
      const valueNow = (): Record<string, unknown> => {
        if (memo === null) {
          memo = currentFormJson(toJson(applyAll(source, actions, backend))) as Record<
            string,
            unknown
          >;
        }
        return memo;
      };
      const doc = {
        get value(): Out {
          return valueNow() as Out;
        },
        get actions(): readonly EditAction[] {
          return [...actions];
        },
        set(pathOrKey: EditPath | string, value: SjonValue) {
          const { path, key } = splitTerminal(
            typeof pathOrKey === 'string' ? [pathOrKey] : pathOrKey,
          );
          actions.push({ op: 'set_keyword', path, key, value });
          memo = path.length === 0 && memo !== null ? { ...memo, [key]: value } : null;
          return doc;
        },
        remove(pathOrKey: EditPath | string) {
          const { path, key } = splitTerminal(
            typeof pathOrKey === 'string' ? [pathOrKey] : pathOrKey,
          );
          actions.push({ op: 'remove_keyword', path, key });
          if (path.length === 0 && memo !== null) {
            const next = { ...memo };
            delete next[key];
            memo = next;
          } else {
            memo = null;
          }
          return doc;
        },
        edit(action: EditAction) {
          actions.push(action);
          memo = null;
          return doc;
        },
        save(saveOptions?: { readonly validate?: boolean }): string {
          const text = applyAll(source, actions, backend);
          if (saveOptions?.validate) {
            const outcome = backend.validate(`${manifest()}\n\n${text}`);
            if (outcome.diagnostics.some((d) => d.severity === 'err')) {
              throw new SjonValidationError(outcome.diagnostics);
            }
          }
          return text;
        },
        safeSave: (): SafeEditResult => safeApplyAll(source, actions, backend),
        toString: (): string => applyAll(source, actions, backend),
      };
      return doc as unknown as FormDocument<NS, Head, Sh>;
    },
  };
  return node as unknown as FormNode<NS, Head, Sh>;
}

// ---------------------------------------------------------------------------
// Plugin node
// ---------------------------------------------------------------------------

interface PluginInit {
  readonly version?: string;
  readonly description?: string;
  readonly forms?: readonly AnyFormNodeLike[];
  readonly kinds?: Readonly<Record<string, AnyNode>>;
  /** `(cross-ref-provider …)` declarations. A schema that references a
   * provider must also declare it, or the aggregate pass answers
   * `unknown_cross_ref_provider`. Declaration only — the implementation
   * ships with the plugin, not with the schema. */
  readonly providers?: Readonly<Record<string, string | undefined>>;
}

type AnyFormNodeLike = { readonly _def: FormDef };

function pluginNode(name: string, init: PluginInit): PluginNode {
  const namedKinds: NamedKindDef[] = Object.entries(init.kinds ?? {}).map(([kindName, n]) => ({
    name: kindName,
    def: { ...(n as AnyNode)._def, suggestedKind: kindName, explicitKind: true },
  }));
  const forms: FormDef[] = (init.forms ?? []).map((f) => ({ ...f._def, ns: name }));
  const crossRefProviders: CrossRefProviderDef[] = Object.entries(init.providers ?? {}).map(
    ([providerName, description]) => ({
      name: providerName,
      ...(description !== undefined ? { description } : {}),
    }),
  );
  const def: PluginDef = {
    name,
    version: init.version ?? '1.0.0',
    forms,
    namedKinds,
    crossRefProviders,
    ...(init.description !== undefined ? { description: init.description } : {}),
  };
  const manifest = (): string => serializePlugin(def);
  const node = {
    _def: def,
    manifest,
    toDts: (options?: ToDtsOptions): string => {
      const backend = requireBackend(options?.backend);
      if (!backend.exportSchema) {
        throw new Error('SJON schema: backend has no `exportSchema` — `.toDts()` is unavailable.');
      }
      return backend.exportSchema(manifest()).tsTypes ?? '';
    },
  };
  return node as unknown as PluginNode;
}

// ---------------------------------------------------------------------------
// The `s` factory
// ---------------------------------------------------------------------------

// The factory is exported as a flat set of top-level bindings; `index.ts`
// re-exports them under the `s` *namespace* (`export * as s`). A module
// namespace — unlike a `const` object — merges value and type members, so
// both `s.string()` (value) and `s.infer<typeof Form>` (type) resolve. This
// is the same trick Zod uses for `z`.

// --- backend wiring ---
export const use = useBackend;

// --- primitives ---
export const any = (): Node<unknown> => leaf({ shape: { kind: 'any' }, isOptional: false });
export const nil = (): Node<null> => leaf({ shape: { kind: 'nil' }, isOptional: false });
export const boolean = (): Node<boolean> => leaf({ shape: { kind: 'boolean' }, isOptional: false });
export const number = (): NumberNode =>
  numberNode({ shape: { kind: 'number' }, isOptional: false });
export const string = (): StringNode =>
  stringNode({ shape: { kind: 'string' }, isOptional: false });
export const symbol = (): Node<Symbol_> => leaf({ shape: { kind: 'symbol' }, isOptional: false });
export const expr = (): Node<SjonExpr> => leaf({ shape: { kind: 'expr' }, isOptional: false });
export const formAny = (): Node<{ readonly $form: string }> =>
  leaf({ shape: { kind: 'form_any' }, isOptional: false });

// --- refined string presets (→ value-kind w/ string-bounds) ---
export const slug = (): StringNode => stringPreset({ pattern: '^[a-z][a-z0-9-]*$' }, 'slug');
export const email = (): StringNode => stringPreset({ format: 'email' }, 'email');
export const url = (): StringNode => stringPreset({ format: 'uri' }, 'url');
export const uuid = (): StringNode => stringPreset({ format: 'uuid' }, 'uuid');
export const semver = (): StringNode => stringPreset({ format: 'semver' }, 'semver');
export const path = (): StringNode => stringPreset({ format: 'path' }, 'path');

// --- enums ---
/**
 * A symbol enum. A member may be spelled digit-leading (`2d`, `2d-array`,
 * `50%`) — the WebGPU-style spelling no bare symbol can express — in which
 * case the slot's value type is `SjonUnit`, not `Symbol_`, because that is
 * what such a spelling lexes as. Invalid spellings throw here rather than
 * becoming an `invalid_manifest` diagnostic later; see `canonicalMemberName`.
 */
export const symbolMembers = <const M extends readonly string[]>(
  members: M,
): Node<MemberSymbol<M[number]>> => {
  // Canonicalise first, then look for repeats *among the canonical names* —
  // two spellings can be one member (`2d` and `2.0d`), which is exactly the
  // duplicate hardest to see in the source. The engine refuses the emitted
  // manifest either way; throwing here names the pair at the call site
  // instead of at load time.
  const canonical = members.map(canonicalMemberName);
  const duplicate = canonical.find((m, i) => canonical.indexOf(m, i + 1) !== -1);
  if (duplicate !== undefined) {
    throw new Error(
      `SJON schema: symbolMembers declares member "${duplicate}" twice — a member set is a set, and two spellings of one magnitude and unit (2d, 2.0d, 02d) are one member.`,
    );
  }
  return leaf({ shape: { kind: 'symbol_members', members: canonical }, isOptional: false });
};
export const stringMembers = <const M extends readonly string[]>(members: M): Node<M[number]> =>
  leaf({ shape: { kind: 'string_members', members: [...members] }, isOptional: false });

// --- composites ---
export function vector<E extends AnyNode>(element: E): VectorNode<E, E['_out'][]>;
export function vector<E extends AnyNode, L extends number>(
  element: E,
  len: L,
): VectorNode<E, FixedTuple<E['_out'], L>>;
export function vector(element: AnyNode, len?: number): AnyNode {
  const shape: ShapeIR =
    len !== undefined
      ? { kind: 'vector', element: element._def.shape, len }
      : { kind: 'vector', element: element._def.shape };
  return leaf({ shape, isOptional: false });
}

/**
 * A typed *nested form* field: the value at this slot must be a `(head …)` of
 * `inner`. Carries `inner`'s `FormDef` so the manifest serializer emits the
 * inner `(form …)` + a `:underlying form` value-kind (`serialize.ts`), `create`
 * recurses to construct it, and the typed path-resolver descends into it.
 * `inner` must already be defined — forms compose as a DAG, not recursively.
 *
 * Declare `inner` with the **same `ns`** as its container (the plugin ns):
 * forms in a plugin share its namespace, so the manifest resolves the inner
 * form to `<plugin-ns>/<head>` and the stamped data must match. With mismatched
 * ns the validator reports `unknown_form`. E.g. for a `todo-app` plugin:
 * `s.form('todo', { … }, 'todo-app')`, then `s.form('todo-app', { items:
 * s.vector(s.formOf(Todo)) })` (whose ns defaults to its head, `todo-app`).
 *
 * ## Recursive (self-referential) forms
 *
 * Pass a **thunk** to reference a form that isn't built yet — a node can nest
 * itself (tree-shaped data): `const Tree = s.form('tree', { value: s.number(),
 * kids: s.vector(s.formOf(() => Tree)) })`. The thunk is stored, not called, at
 * build time (no infinite loop); it resolves lazily during serialize/construct,
 * where the serializer's head-dedup terminates the declaration cycle and
 * construction bottoms out on finite data. A recursive form's output type needs
 * an **explicit annotation** to break TS's value-circular reference, and typed
 * deep edit paths into the recursive region cap at the `Depth` budget — both are
 * TS-compiler limits, documented on `FormFieldNode` in `infer.ts`.
 */
export function formOf<NS extends string, Head extends string, Sh extends ShapeRecord>(
  inner: FormNode<NS, Head, Sh>,
): FormFieldNode<NS, Head, Sh>;
export function formOf<NS extends string, Head extends string, Sh extends ShapeRecord>(
  inner: () => FormNode<NS, Head, Sh>,
): FormFieldNode<NS, Head, Sh>;
export function formOf<NS extends string, Head extends string, Sh extends ShapeRecord>(
  inner: FormNode<NS, Head, Sh> | (() => FormNode<NS, Head, Sh>),
): FormFieldNode<NS, Head, Sh> {
  // A FormNode is a plain object; only the lazy form is a function. Store the
  // thunk unevaluated so a self-reference (`() => Self`) doesn't trip TS's TDZ
  // or recurse forever — `resolveFormDef` calls it lazily later.
  const form: FormDef | (() => FormDef) =
    typeof inner === 'function' ? () => inner()._def : inner._def;
  return leaf({
    shape: { kind: 'form', form },
    isOptional: false,
  }) as unknown as FormFieldNode<NS, Head, Sh>;
}

/**
 * A symbol slot narrowed to names the *document* supplies.
 *
 * Two routes, mutually exclusive. Identity (`nameKey`, the default) reads
 * a symbol out of each target instance. Provider (`provider` +
 * `sourceKey`) reads an opaque *string* out of each instance and lets a
 * declared extractor name the members inside it — for embedded GLSL, DDL,
 * or a regex.
 *
 * The exclusions throw here rather than emitting a manifest the loader
 * would reject with `invalid_manifest`: a builder's job is to make the
 * illegal state unconstructible, and the stack trace at the call site
 * beats a diagnostic three layers down.
 */
/**
 * A cross-reference slot. `s.crossRef('account')` names one target form;
 * `s.crossRef(['render-pipeline', 'compute-pipeline'])` names several,
 * which declares that the listed forms share **one namespace** — a name
 * from any of them satisfies a reference, and a name defined by two of
 * them is `duplicate_cross_ref_target` at validate time.
 *
 * The value type distributes: a group is a union of `CrossRef` brands, one
 * per target, which is the honest reading of "this name may come from
 * either form".
 *
 * Two options are rejected on a group, matching the engine's loader rather
 * than emitting a manifest it would refuse: `acyclic` (cycle edges are a
 * target's *self*-referential keys, and "self" is not well defined across
 * several forms) and `provider` (an extracted member set is collected per
 * target form — declare one cross-ref per target instead).
 */
export const crossRef = <const Target extends string>(
  target: Target | readonly Target[],
  options?: {
    readonly nameKey?: string;
    readonly acyclic?: boolean;
    readonly scope?: string;
    readonly provider?: string;
    readonly sourceKey?: string;
  },
): Node<CrossRef<Target>> => {
  const targets: readonly string[] = typeof target === 'string' ? [target] : target;
  if (targets.length === 0) {
    throw new Error(
      'SJON schema: crossRef needs at least one target — an empty target list accepts nothing and rejects everything.',
    );
  }
  const duplicate = targets.find((t, i) => targets.indexOf(t, i + 1) !== -1);
  if (duplicate !== undefined) {
    throw new Error(
      `SJON schema: crossRef lists target "${duplicate}" twice — the group is one namespace, so the repeat adds nothing and hides a likely typo.`,
    );
  }
  if (targets.length > 1) {
    if (options?.acyclic === true) {
      throw new Error(
        "SJON schema: crossRef `acyclic` needs a single target — cycle edges are defined over one form's self-referential keys, and `self` is not well defined across a group.",
      );
    }
    if (options?.provider !== undefined) {
      throw new Error(
        'SJON schema: crossRef `provider` needs a single target — an extracted member set is collected per target form, so declare one cross-ref per target.',
      );
    }
  }
  if (options?.provider !== undefined) {
    if (options.nameKey !== undefined) {
      throw new Error(
        'SJON schema: crossRef `provider` and `nameKey` are exclusive extraction routes — pick one.',
      );
    }
    if (options.acyclic === true) {
      throw new Error(
        'SJON schema: crossRef `acyclic` is identity-route only — extracted names share one source span, so cycle edges are undefined.',
      );
    }
  } else if (options?.sourceKey !== undefined) {
    throw new Error(
      'SJON schema: crossRef `sourceKey` needs a `provider` — nothing reads it on the identity route.',
    );
  }
  const crossRef: CrossRefIR = {
    targets,
    ...(options?.nameKey !== undefined ? { nameKey: options.nameKey } : {}),
    ...(options?.acyclic !== undefined ? { acyclic: options.acyclic } : {}),
    ...(options?.scope !== undefined ? { scope: options.scope } : {}),
    ...(options?.provider !== undefined ? { provider: options.provider } : {}),
    ...(options?.sourceKey !== undefined ? { sourceKey: options.sourceKey } : {}),
  };
  return leaf({ shape: { kind: 'cross_ref', crossRef }, isOptional: false });
};

// --- declarations ---
/** An explicitly-named value-kind (`s.kind("score", s.number().min(0).max(100))`). */
export const kind = <N extends AnyNode>(name: string, node: N): N => {
  const def: NodeDef = { ...node._def, suggestedKind: name, explicitKind: true };
  return rebuildNode(def) as unknown as N;
};

/**
 * Rebuild a node from a (possibly modified) def through the factory that owns
 * its shape, so shape-specific refinement methods (`.min`, `.max`, `.pattern`,
 * …) survive. A bare `leaf` strips them — the phantom `kind` used to return,
 * whose `.min` threw at call time. Exhaustive over `ShapeIR` so a future
 * method-carrying factory can't be silently forgotten here.
 */
function rebuildNode(def: NodeDef): AnyNode {
  const shapeKind = def.shape.kind;
  switch (shapeKind) {
    case 'number':
      return numberNode(def) as unknown as AnyNode;
    case 'string':
      return stringNode(def) as unknown as AnyNode;
    case 'any':
    case 'nil':
    case 'boolean':
    case 'symbol':
    case 'symbol_members':
    case 'string_members':
    case 'vector':
    case 'expr':
    case 'form_any':
    case 'form':
    case 'cross_ref':
      return leaf(def);
    default:
      return assertNever(shapeKind);
  }
}

/** A `(form …)`. `ns` (the data form's `$ns`) defaults to the form head. */
export const form = <Head extends string, Sh extends ShapeRecord, NS extends string = Head>(
  head: Head,
  shape: Sh,
  ns?: NS,
): FormNode<NS, Head, Sh> => formNode<NS, Head, Sh>(buildFormDef(head, shape, (ns ?? head) as NS));

/** A `(plugin …)` grouping forms + named kinds (for multi-form / cross-ref docs). */
export const plugin = (name: string, init: PluginInit = {}): PluginNode => pluginNode(name, init);

// Type-only helpers, surfaced as `s.infer<typeof Form>` / `s.input<…>`.
export type { infer, input } from './infer.ts';
