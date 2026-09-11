// Validator — second-host TypeScript implementation.
//
// Walks an AST tree against a Schema, emits diagnostics. Not a
// complete port: covers the rules exercised by `conformance/cases/`.
// Each diagnostic carries a semantic path matching the Zig
// reference's path semantics:
//
//   * forms contribute their head;
//   * kvpairs contribute their key;
//   * vector elements contribute their decimal index;
//   * a form value at a kvpair adds the form's head as a step.
//
// See `docs/portable-manifest-v1.md` §11.1 for the contract.
//
// Cross-ref scoping & acyclic enforcement mirror `src/Validator.zig`:
// references resolve only against names registered under a matching
// `ScopeId` (per-tree default; lexical when the cross-ref opts into
// `:scope <form>`), and `:acyclic true` cross-refs are checked with
// iterative DFS coloring on the per-scope graph captured during the
// index pass.
//
// House rule for this file: narrow, never cast. Every walk here is a
// `switch (node.tag)` or an early `if (node.tag !== …) return`, which
// already narrows `Node` to the variant — a following `node as FormNode`
// buys nothing and costs the guarantee, because a cast keeps compiling
// after someone edits the guard above it while narrowing stops. Ten of
// these had accumulated; they're gone. Biome's narrowed rule set
// (correctness + suspicious) has no no-unnecessary-assertion rule, so
// this one is on review.

import type { Node, FormNode, KvPairNode, NumberNode, Span } from './ast.ts';
import type { Diagnostic, DiagnosticCode } from './diagnostics.ts';
import type {
  Schema,
  Alternative,
  ExclusiveGroup,
  FormSpec,
  ExprFunc,
  Head,
  HeadSet,
  KeySpec,
  Member,
  ValueType,
  ValueKind,
  NumericBound,
  NumericBounds,
  QualifiedRef,
  Repr,
  StringBounds,
  Variant,
} from './plugin.ts';
import {
  MAX_KIND_DEPTH,
  canonicalSpelling,
  checkArity,
  crossRefBucketKey,
  describeBucket,
  headSetIsUnbounded,
  effectiveOptional,
  lookupExprFunc,
  lookupForm,
  lookupValueKind,
  paramTypeAt,
  spellingKeyOf,
  variantSelects,
  variantWhenText,
} from './plugin.ts';
import * as StringFormats from './stringFormats.ts';

// ─── Form-expression result resolution (TS mirror) ──────────────────
//
// Mirrors `resolveFormExpression` in `src/Validator.zig`. Used by typed
// slot matching and expression-argument checking to peek at a form-
// valued node's declared result type without evaluating it. The
// TS-parity host only models mono `ExprFunc` (no multi-signature), so
// the resolver is simpler than the Zig version.

type FormExprResolution =
  | { kind: 'data_form' }
  | { kind: 'expr'; func: ExprFunc; result: ValueType | null }
  | { kind: 'unresolved' };

function resolveFormExpression(schema: Schema, node: Node): FormExprResolution {
  if (node.tag !== 'form') return { kind: 'unresolved' };
  const fn = node;
  if (fn.head.length === 0) return { kind: 'unresolved' };
  const formHit = lookupForm(schema, fn.head, fn.namespace);
  if (formHit.kind === 'found') return { kind: 'data_form' };
  if (formHit.kind === 'ambiguous') return { kind: 'unresolved' };
  const exprHit = lookupExprFunc(schema, fn.head, fn.namespace);
  if (exprHit.kind !== 'found') return { kind: 'unresolved' };
  return { kind: 'expr', func: exprHit.value, result: exprHit.value.result };
}

type DeclaredTypeMatch = 'yes' | 'no' | 'unknown';

function isAnyType(t: ValueType): boolean {
  return t.kind === 'any' || (t.kind === 'named' && t.name === 'any');
}

const PRIMITIVE_NORMALIZE: ReadonlyMap<string, ValueType['kind']> = new Map([
  ['any', 'any'],
  ['number', 'number'],
  ['string', 'string'],
  ['symbol', 'symbol'],
  ['boolean', 'boolean'],
  ['nil', 'nil'],
  ['vector', 'vector'],
  ['form', 'form'],
  ['expr', 'expr'],
]);

function normalizeTypeName(t: ValueType): ValueType {
  if (t.kind !== 'named') return t;
  const norm = PRIMITIVE_NORMALIZE.get(t.name);
  if (!norm) return t;
  if (
    norm === 'any' ||
    norm === 'number' ||
    norm === 'string' ||
    norm === 'symbol' ||
    norm === 'boolean' ||
    norm === 'nil' ||
    norm === 'vector' ||
    norm === 'form' ||
    norm === 'expr'
  ) {
    return { kind: norm } as ValueType;
  }
  return t;
}

type PrimitiveUnderlying = 'number' | 'string' | 'symbol' | 'boolean' | 'nil' | 'vector';

function primitiveOf(schema: Schema, t: ValueType): PrimitiveUnderlying | null {
  switch (t.kind) {
    case 'number':
      return 'number';
    case 'string':
      return 'string';
    case 'symbol':
      return 'symbol';
    case 'boolean':
      return 'boolean';
    case 'nil':
      return 'nil';
    case 'vector':
      return 'vector';
    case 'any':
    case 'form':
    case 'expr':
      return null;
    case 'named': {
      const k = lookupValueKind(schema, t.name, t.namespace);
      if (k.kind !== 'found') return null;
      switch (k.value.underlying) {
        case 'number':
          return 'number';
        case 'string':
          return 'string';
        case 'symbol':
          return 'symbol';
        case 'vector':
          return 'vector';
        case 'form':
          return null;
        case 'union_of':
          return null;
      }
    }
  }
}

function kindHasRefinements(k: ValueKind): boolean {
  return Boolean(k.vector || k.unit || k.members || k.heads || k.crossRef);
}

function valueTypesEqual(a: ValueType, b: ValueType): boolean {
  if (a.kind !== b.kind) return false;
  if (a.kind === 'named' && b.kind === 'named') return a.name === b.name;
  return true;
}

function declaredResultMatchesExpected(
  schema: Schema,
  actual: ValueType,
  expected: ValueType,
): DeclaredTypeMatch {
  if (isAnyType(expected)) return 'yes';
  if (isAnyType(actual)) return 'unknown';
  const aNorm = normalizeTypeName(actual);
  const eNorm = normalizeTypeName(expected);
  if (valueTypesEqual(aNorm, eNorm)) return 'yes';
  const aPrim = primitiveOf(schema, aNorm);
  const ePrim = primitiveOf(schema, eNorm);
  if (aPrim === null || ePrim === null) return 'unknown';
  if (aPrim !== ePrim) return 'no';
  if (eNorm.kind === 'named') {
    const k = lookupValueKind(schema, eNorm.name, eNorm.namespace);
    if (k.kind !== 'found') return 'unknown';
    if (kindHasRefinements(k.value)) return 'unknown';
  }
  return 'yes';
}

function typeLabel(t: ValueType): string {
  switch (t.kind) {
    case 'any':
      return 'any value';
    case 'number':
      return 'number';
    case 'string':
      return 'string';
    case 'symbol':
      return 'symbol';
    case 'boolean':
      return 'boolean';
    case 'nil':
      return 'nil';
    case 'vector':
      return 'vector';
    case 'form':
      return 'form';
    case 'expr':
      return 'expression';
    case 'named':
      return t.name;
  }
}

/// Three-way verdict on a form-in-typed-slot: null = accept (or defer),
/// MatchFail = emit. Used by `matchType` / `matchKind` and the expr-arg
/// path so the dispatch logic stays in one place.
function checkFormInTypedSlot(schema: Schema, node: Node, expected: ValueType): MatchFail | null {
  if (isAnyType(expected)) return null;
  if (expected.kind === 'form') return null;
  if (expected.kind === 'expr') {
    const res = resolveFormExpression(schema, node);
    if (res.kind === 'data_form') return wrongUnderlying(typeLabel(expected));
    return null;
  }
  const res = resolveFormExpression(schema, node);
  if (res.kind === 'data_form') return wrongUnderlying(typeLabel(expected));
  if (res.kind === 'unresolved') return null;
  const declared = res.result;
  if (!declared) return null;
  const verdict = declaredResultMatchesExpected(schema, declared, expected);
  return verdict === 'no' ? wrongUnderlying(typeLabel(expected)) : null;
}

// ─── Scope identity ──────────────────────────────────────────────────

type ScopeId = string;
const treeScopeId = (treeIdx: number): ScopeId => `t:${treeIdx}`;
const lexicalScopeId = (treeIdx: number, openerStart: number): ScopeId =>
  `l:${treeIdx}:${openerStart}`;

interface ScopeFrame {
  readonly canonical: string;
  readonly scopeId: ScopeId;
}

function findNearestScope(chain: readonly ScopeFrame[], canonical: string): ScopeId | null {
  for (let i = chain.length - 1; i >= 0; i--) {
    if (chain[i]!.canonical === canonical) return chain[i]!.scopeId;
  }
  return null;
}

// ─── Cross-ref registry ──────────────────────────────────────────────

interface CrossRefTargetSpec {
  readonly canonicalTarget: string;
  readonly nameKey: string;
  readonly scopeForm: string | null; // canonical <plugin>/<form>, or null
  readonly acyclic: boolean;
}

interface CrossRefRegistry {
  readonly byScope: ReadonlyMap<
    ScopeId,
    ReadonlyMap<string /*canonicalTarget*/, ReadonlySet<string /*name*/>>
  >;
  // Bare form-head → canonical target spec. Cross-ref targets are
  // looked up by the registered form's bare head during the document
  // walk (the document doesn't carry plugin qualifiers on heads).
  /** Bare form head → every bucket that head's instances register into:
   * its own (from a single-target cross-ref) plus one per group listing
   * it. One entry for every schema written before multi-target
   * cross-refs. Mirrors Zig's one-to-many `collectCrossRefTargets`. */
  readonly targetsByHead: ReadonlyMap<string, readonly CrossRefTargetSpec[]>;
  // Cross-ref kind name → its target spec, for the validator's resolve
  // path which knows the kind, not the head.
  readonly targetsByKind: ReadonlyMap<string, CrossRefTargetSpec>;
  readonly scopeOpeners: ReadonlySet<string>; // canonical scope-opener forms
  readonly cycleDiags: readonly Diagnostic[];
  /**
   * The symbol a *held* position is spelled with: a value the author has
   * deliberately not filled in yet. `null` for every run that has not opted
   * in, which validates exactly as it did before the field existed.
   *
   * Rides on the registry for the reason `Validator.zig` gives: the index is
   * the one object already threaded to every match site AND to the
   * registration walk, and a held name registers nothing (matching is not
   * the only thing a symbol does in a cross-ref schema).
   */
  readonly heldSymbol: string | null;
}

/** True when `node` is the run's held spelling. */
function isHeld(registry: CrossRefRegistry, node: Node): boolean {
  return registry.heldSymbol !== null && node.tag === 'symbol' && node.text === registry.heldSymbol;
}

// ─── Schema helpers ─────────────────────────────────────────────────

function lookupFormFull(
  schema: Schema,
  name: string,
  ns: string | null,
): { pluginName: string; form: FormSpec } | null {
  for (const p of schema.plugins) {
    if (ns && p.name !== ns) continue;
    for (const f of p.forms) {
      if (f.name === name) return { pluginName: p.name, form: f };
    }
    if (ns) return null;
  }
  return null;
}

function canonicalize(schema: Schema, qualified: string): string | null {
  const slash = qualified.indexOf('/');
  const ns = slash >= 0 ? qualified.slice(0, slash) : null;
  const bare = slash >= 0 ? qualified.slice(slash + 1) : qualified;
  const hit = lookupFormFull(schema, bare, ns);
  if (!hit) return null;
  return `${hit.pluginName}/${hit.form.name}`;
}

function bareFromCanonical(canonical: string): string {
  const slash = canonical.indexOf('/');
  return slash >= 0 ? canonical.slice(slash + 1) : canonical;
}

// `:acyclic true` self-edge shape detection. Mirrors `selfEdgeShape`
// in `src/Schema.zig`.
type EdgeShape = 'scalar' | 'vector';

function selfEdgeShape(schema: Schema, valueType: ValueType, kindName: string): EdgeShape | null {
  if (valueType.kind === 'named' && valueType.name === kindName) return 'scalar';
  if (valueType.kind === 'named') {
    const refKind = lookupValueKind(schema, valueType.name, valueType.namespace);
    if (
      refKind.kind === 'found' &&
      refKind.value.underlying === 'vector' &&
      refKind.value.vector?.element.name === kindName
    ) {
      return 'vector';
    }
  }
  return null;
}

// ─── Acyclic spec collection ─────────────────────────────────────────

interface AcyclicSpec {
  readonly kindName: string;
  readonly canonicalTarget: string;
  readonly nameKey: string;
  readonly scopeForm: string | null;
  readonly edges: readonly { name: string; shape: EdgeShape }[];
}

function collectAcyclicSpecs(schema: Schema): AcyclicSpec[] {
  const out: AcyclicSpec[] = [];
  for (const p of schema.plugins) {
    for (const k of p.valueKinds) {
      const cr = k.crossRef;
      if (!cr || !cr.acyclic) continue;
      // Single-target by construction: the loader rejects `:acyclic true`
      // on a group, because cycle edges are a target's *self*-referential
      // keys and "self" is not well defined across several forms.
      if (cr.targets.length !== 1) continue;
      const canonicalTarget = canonicalize(schema, cr.targets[0]!);
      if (!canonicalTarget) continue;
      const targetBare = bareFromCanonical(canonicalTarget);
      const targetForm = lookupFormFull(schema, targetBare, canonicalTarget.split('/')[0]!);
      if (!targetForm) continue;
      const nameKey = cr.nameKey ?? 'name';
      const edges: { name: string; shape: EdgeShape }[] = [];
      for (const key of targetForm.form.keys) {
        if (key.name === nameKey) continue;
        const shape = selfEdgeShape(schema, key.valueType, k.name);
        if (shape) edges.push({ name: key.name, shape });
      }
      if (edges.length === 0) continue;
      const scopeForm = cr.scopeForm ? canonicalize(schema, cr.scopeForm) : null;
      out.push({
        kindName: k.name,
        canonicalTarget,
        nameKey,
        scopeForm,
        edges,
      });
    }
  }
  return out;
}

// ─── Validate entry ──────────────────────────────────────────────────

export function validate(
  schema: Schema,
  roots: readonly Node[],
  heldSymbol: string | null = null,
): readonly Diagnostic[] {
  const diags: Diagnostic[] = [];

  // Pre-pass: build cross-ref registry over the forest, capturing
  // duplicate-name diagnostics, lexical scope frames, and per-scope
  // edge graphs for cycle detection.
  const registry = buildCrossRefIndex(schema, roots, diags, heldSymbol);

  // Cycle detection diagnostics live at the document level (path =
  // []), parallel to `duplicate_cross_ref_target`. Append once.
  for (const d of registry.cycleDiags) diags.push(d);

  // Convention (matches `Validator.zig`): the path passed to visit
  // already includes the node's own contribution. Root forms enter
  // with `[head]`.
  // The conformance harness passes one document's roots as a flat
  // array — they share a single tree (Zig's `validate` does the same:
  // bundles into a 1-tree forest). Per-tree isolation is therefore
  // moot here; everything keys under `treeScopeId(0)` until a fixture
  // genuinely exercises multi-tree validation.
  const treeScope = treeScopeId(0);
  for (const root of roots) {
    const rootPath = root.tag === 'form' && root.head.length > 0 ? [root.head] : [];
    visit(schema, registry, root, rootPath, [], treeScope, 0, diags, null);
  }
  return diags;
}

// ─── Index pass ──────────────────────────────────────────────────────

interface CycleNode {
  readonly name: string;
  readonly treeIdx: number;
  readonly nameSpan: Span;
  readonly edges: readonly string[];
}

function buildCrossRefIndex(
  schema: Schema,
  roots: readonly Node[],
  diags: Diagnostic[],
  heldSymbol: string | null,
): CrossRefRegistry {
  // 1. Cross-ref kinds → canonical target specs.
  const targetsByHead = new Map<string, CrossRefTargetSpec[]>();
  const targetsByKind = new Map<string, CrossRefTargetSpec>();
  for (const p of schema.plugins) {
    for (const k of p.valueKinds) {
      const cr = k.crossRef;
      if (!cr) continue;
      // `canonicalTarget` is the *bucket*: the canonical form name for one
      // target, a synthetic group key for several. Every listed target's
      // instances register into it, which is what keeps lookup a
      // single-bucket operation.
      const canonicalTarget = crossRefBucketKey(schema, cr);
      if (!canonicalTarget) continue;
      const scopeForm = cr.scopeForm ? canonicalize(schema, cr.scopeForm) : null;
      const spec: CrossRefTargetSpec = {
        canonicalTarget,
        nameKey: cr.nameKey ?? 'name',
        scopeForm,
        acyclic: cr.acyclic ?? false,
      };
      for (const spelling of cr.targets) {
        const canonicalOne = canonicalize(schema, spelling);
        if (!canonicalOne) continue;
        const bareHead = bareFromCanonical(canonicalOne);
        const list = targetsByHead.get(bareHead);
        if (list === undefined) {
          targetsByHead.set(bareHead, [spec]);
          continue;
        }
        // First-wins *per bucket*: a second kind landing in a bucket this
        // head already feeds sets nothing (and
        // `cross_ref_target_collapse` warns). A different bucket is a
        // different namespace and gets its own entry.
        if (list.some((e) => e.canonicalTarget === canonicalTarget)) continue;
        list.push(spec);
      }
      targetsByKind.set(k.name, spec);
    }
  }

  // 2. Acyclic specs (subset with `:acyclic true` and self-edges).
  const acyclicSpecs = collectAcyclicSpecs(schema);

  // 3. Scope-opener canonicals: union of every cross-ref's scope_form.
  const scopeOpeners = new Set<string>();
  for (const specs of targetsByHead.values()) {
    for (const t of specs) {
      if (t.scopeForm) scopeOpeners.add(t.scopeForm);
    }
  }
  for (const s of acyclicSpecs) {
    if (s.scopeForm) scopeOpeners.add(s.scopeForm);
  }

  // 4. Mutable accumulators.
  const byScope = new Map<ScopeId, Map<string, Set<string>>>();
  const cycleNodesBySpec: Map<ScopeId, CycleNode[]>[] = acyclicSpecs.map(() => new Map());

  if (targetsByHead.size === 0 && acyclicSpecs.length === 0 && scopeOpeners.size === 0) {
    return {
      byScope,
      targetsByHead,
      targetsByKind,
      scopeOpeners,
      cycleDiags: [],
      heldSymbol,
    };
  }

  // 5. Walk all roots as siblings of a single tree (matches Zig's
  //    single-tree `validate` wrapper).
  const treeScope = treeScopeId(0);
  const scopeStack: ScopeFrame[] = [];
  for (const root of roots) {
    walkIndex(
      schema,
      root,
      0,
      treeScope,
      scopeStack,
      targetsByHead,
      acyclicSpecs,
      scopeOpeners,
      byScope,
      cycleNodesBySpec,
      diags,
      heldSymbol,
      [],
    );
  }

  // 6. Cycle detection.
  const cycleDiags: Diagnostic[] = [];
  for (let i = 0; i < acyclicSpecs.length; i++) {
    const spec = acyclicSpecs[i]!;
    const perScope = cycleNodesBySpec[i]!;
    for (const nodes of perScope.values()) {
      runAcyclicSpec(spec, nodes, cycleDiags);
    }
  }

  return {
    byScope,
    targetsByHead,
    targetsByKind,
    scopeOpeners,
    cycleDiags,
    heldSymbol,
  };
}

function walkIndex(
  schema: Schema,
  node: Node,
  treeIdx: number,
  treeScope: ScopeId,
  scopeStack: ScopeFrame[],
  targetsByHead: ReadonlyMap<string, readonly CrossRefTargetSpec[]>,
  acyclicSpecs: readonly AcyclicSpec[],
  scopeOpeners: ReadonlySet<string>,
  byScope: Map<ScopeId, Map<string, Set<string>>>,
  cycleNodesBySpec: Map<ScopeId, CycleNode[]>[],
  diags: Diagnostic[],
  heldSymbol: string | null,
  /**
   * Slot-local registry this node's head resolves against before the global
   * catalog — the same thing `visit` carries as `LocalFormScope.registry`.
   * This pass needs it for one reason: to know which `FormSpec` a head
   * resolved to, so a `:walk-opaque` slot can stop the descent here as it
   * does there. Empty for the overwhelming majority of nodes.
   */
  registry: readonly FormSpec[],
): void {
  if (node.tag === 'form') {
    const canonical = canonicalize(schema, namespacedHead(node));
    let pushed = false;
    if (canonical && scopeOpeners.has(canonical)) {
      scopeStack.push({
        canonical,
        scopeId: lexicalScopeId(treeIdx, node.headSpan.start),
      });
      pushed = true;
    }

    // Register into every bucket this head feeds.
    for (const targetSpec of targetsByHead.get(node.head) ?? []) {
      registerInstance(node, targetSpec, treeScope, scopeStack, byScope, diags, heldSymbol);
    }

    for (let i = 0; i < acyclicSpecs.length; i++) {
      const spec = acyclicSpecs[i]!;
      if (canonical !== spec.canonicalTarget) continue;
      captureCycleNode(node, treeIdx, spec, treeScope, scopeStack, cycleNodesBySpec[i]!);
    }

    // Slot-aware descent, matching `visit`'s. A subtree the surrounding
    // schema declined to interpret is not a place to harvest cross-ref
    // targets, scopes or cycle edges out of either, so a `:walk-opaque`
    // slot's value is never recursed into.
    let ownSpec: FormSpec | null = null;
    if (node.namespace === null) {
      for (const lf of registry) {
        if (lf.name === node.head) {
          ownSpec = lf;
          break;
        }
      }
    }
    if (!ownSpec) {
      const r = lookupForm(schema, node.head, node.namespace);
      if (r.kind === 'found') ownSpec = r.value;
    }
    // The active variant while walking the children in order, exactly as
    // `visit` resolves it: a variant key ahead of its discriminant is
    // `unknown_key` and puts nothing in scope. No overlay leg — this port
    // has no materialized defaults.
    let activeVariant: Variant | null = null;
    for (const ch of node.children) {
      let childRegistry: readonly FormSpec[] = [];
      if (ch.tag === 'kvpair') {
        let matchedKey: KeySpec | null = null;
        if (ownSpec) {
          const commonIdx = ownSpec.keys.findIndex((k) => k.name === ch.key);
          if (commonIdx >= 0) {
            matchedKey = ownSpec.keys[commonIdx]!;
            if (ownSpec.discriminantIdx === commonIdx && ch.value.tag === 'symbol') {
              const sym = ch.value.text;
              const selected = (ownSpec.variants ?? []).find((v) => variantSelects(v, sym));
              if (selected) activeVariant = selected;
            }
          } else if (activeVariant) {
            matchedKey = activeVariant.keys.find((vk) => vk.name === ch.key) ?? null;
          }
        }
        if (matchedKey?.walkOpaque) continue;
        childRegistry = matchedKey?.localForms ?? [];
      } else if (ch.tag === 'form') {
        childRegistry = ownSpec?.localForms ?? [];
      }
      walkIndex(
        schema,
        ch,
        treeIdx,
        treeScope,
        scopeStack,
        targetsByHead,
        acyclicSpecs,
        scopeOpeners,
        byScope,
        cycleNodesBySpec,
        diags,
        heldSymbol,
        childRegistry,
      );
    }

    if (pushed) scopeStack.pop();
  } else if (node.tag === 'vector') {
    for (const e of node.elements) {
      walkIndex(
        schema,
        e,
        treeIdx,
        treeScope,
        scopeStack,
        targetsByHead,
        acyclicSpecs,
        scopeOpeners,
        byScope,
        cycleNodesBySpec,
        diags,
        heldSymbol,
        registry,
      );
    }
  } else if (node.tag === 'kvpair') {
    // Only reachable for a kvpair handed in as a root; a kvpair *child* had
    // its slot decided by the form arm above.
    walkIndex(
      schema,
      node.value,
      treeIdx,
      treeScope,
      scopeStack,
      targetsByHead,
      acyclicSpecs,
      scopeOpeners,
      byScope,
      cycleNodesBySpec,
      diags,
      heldSymbol,
      registry,
    );
  }
}

function namespacedHead(form: FormNode): string {
  return form.namespace ? `${form.namespace}/${form.head}` : form.head;
}

function pickRegistrationScope(
  spec: { scopeForm: string | null },
  scopeStack: readonly ScopeFrame[],
  treeScope: ScopeId,
): ScopeId {
  if (!spec.scopeForm) return treeScope;
  return findNearestScope(scopeStack, spec.scopeForm) ?? treeScope;
}

function registerInstance(
  form: FormNode,
  spec: CrossRefTargetSpec,
  treeScope: ScopeId,
  scopeStack: readonly ScopeFrame[],
  byScope: Map<ScopeId, Map<string, Set<string>>>,
  diags: Diagnostic[],
  heldSymbol: string | null,
): void {
  // Lexical tolerance: silently skip when the kvpair is missing or
  // its value isn't a symbol — those errors surface elsewhere
  // (missing-required-key / wrong_underlying).
  for (const ch of form.children) {
    if (ch.tag !== 'kvpair') continue;
    if (ch.key !== spec.nameKey) continue;
    if (ch.value.tag !== 'symbol') return;
    // A held name is not a name: it does not collide with another held
    // name, and it is not a target anything else can reach. Without this
    // the cold start the option exists to serve — several half-written
    // forms, each holding its `:name` — collects a
    // `duplicate_cross_ref_target` on every one after the first.
    if (heldSymbol !== null && ch.value.text === heldSymbol) return;
    const scopeId = pickRegistrationScope(spec, scopeStack, treeScope);
    let scopeMap = byScope.get(scopeId);
    if (!scopeMap) {
      scopeMap = new Map();
      byScope.set(scopeId, scopeMap);
    }
    let nameSet = scopeMap.get(spec.canonicalTarget);
    if (!nameSet) {
      nameSet = new Set();
      scopeMap.set(spec.canonicalTarget, nameSet);
    }
    const text = ch.value.text;
    if (nameSet.has(text)) {
      // The *bucket*, not `form.head`: the head is the bare spelling of
      // whichever form happens to sit at this span, where the collision is
      // a property of the registry the group's targets share. A group also
      // needs its own preposition — `on form` names one form and this is a
      // set of them.
      const shown = describeBucket(spec.canonicalTarget);
      diags.push({
        code: 'duplicate_cross_ref_target',
        message: `duplicate cross-ref name \`${text}\` ${shown.isGroup ? 'across forms' : 'on form'} \`${shown.text}\``,
        path: [],
        span: ch.value.span,
        severity: 'err',
      });
    } else {
      nameSet.add(text);
    }
    return;
  }
}

function captureCycleNode(
  form: FormNode,
  treeIdx: number,
  spec: AcyclicSpec,
  treeScope: ScopeId,
  scopeStack: readonly ScopeFrame[],
  perScope: Map<ScopeId, CycleNode[]>,
): void {
  let name: string | null = null;
  let nameSpan: Span | null = null;
  const edges: string[] = [];
  for (const ch of form.children) {
    if (ch.tag !== 'kvpair') continue;
    if (ch.key === spec.nameKey) {
      if (ch.value.tag === 'symbol') {
        name = ch.value.text;
        nameSpan = ch.value.span;
      }
      continue;
    }
    const edgeKey = spec.edges.find((e) => e.name === ch.key);
    if (!edgeKey) continue;
    if (edgeKey.shape === 'scalar') {
      if (ch.value.tag === 'symbol') edges.push(ch.value.text);
    } else {
      if (ch.value.tag !== 'vector') continue;
      for (const elem of ch.value.elements) {
        if (elem.tag === 'symbol') edges.push(elem.text);
      }
    }
  }
  if (name === null || nameSpan === null) return;
  const scopeId = pickRegistrationScope(spec, scopeStack, treeScope);
  let list = perScope.get(scopeId);
  if (!list) {
    list = [];
    perScope.set(scopeId, list);
  }
  list.push({ name, treeIdx, nameSpan, edges });
}

// ─── Cycle detector ──────────────────────────────────────────────────

function runAcyclicSpec(spec: AcyclicSpec, nodes: readonly CycleNode[], diags: Diagnostic[]): void {
  if (nodes.length === 0) return;
  const COLOR_WHITE = 0;
  const COLOR_GRAY = 1;
  const COLOR_BLACK = 2;
  const color = new Uint8Array(nodes.length);

  const lookupNodeIdx = (name: string): number => {
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i]!.name === name) return i;
    }
    return -1;
  };

  for (let start = 0; start < nodes.length; start++) {
    if (color[start] !== COLOR_WHITE) continue;
    color[start] = COLOR_GRAY;
    const stack: { nodeIdx: number; edgeIdx: number }[] = [{ nodeIdx: start, edgeIdx: 0 }];
    while (stack.length > 0) {
      const frame = stack[stack.length - 1]!;
      const node = nodes[frame.nodeIdx]!;
      if (frame.edgeIdx >= node.edges.length) {
        color[frame.nodeIdx] = COLOR_BLACK;
        stack.pop();
        continue;
      }
      const edgeTarget = node.edges[frame.edgeIdx]!;
      frame.edgeIdx++;
      const targetIdx = lookupNodeIdx(edgeTarget);
      if (targetIdx < 0) continue;
      const tc = color[targetIdx];
      if (tc === COLOR_BLACK) continue;
      if (tc === COLOR_GRAY) {
        let startIdx = stack.length;
        for (let i = 0; i < stack.length; i++) {
          if (stack[i]!.nodeIdx === targetIdx) {
            startIdx = i;
            break;
          }
        }
        if (startIdx < stack.length) {
          emitCyclicCrossRef(spec.kindName, nodes, stack.slice(startIdx), diags);
        }
        continue;
      }
      color[targetIdx] = COLOR_GRAY;
      stack.push({ nodeIdx: targetIdx, edgeIdx: 0 });
    }
  }
}

function emitCyclicCrossRef(
  kindName: string,
  nodes: readonly CycleNode[],
  cycle: readonly { nodeIdx: number; edgeIdx: number }[],
  diags: Diagnostic[],
): void {
  const names = cycle.map((sf) => nodes[sf.nodeIdx]!.name);
  const rendered = `${names.join(' -> ')} -> ${names[0]}`;
  for (const sf of cycle) {
    const node = nodes[sf.nodeIdx]!;
    diags.push({
      code: 'cyclic_cross_ref',
      message: `cyclic reference through \`${kindName}\` cross-ref: \`${rendered}\``,
      path: [],
      span: node.nameSpan,
      severity: 'err',
    });
  }
}

// ─── Main walk ───────────────────────────────────────────────────────

/// Slot-local form registry in scope for the node being visited. Set on a
/// form value frame when the enclosing slot carries local forms — either a
/// keyed slot (`KeySpec.localForms`, e.g. `[canvas shape]`) or a form's
/// positional slot (`FormSpec.localForms`, e.g. `[canvas]`). The value's head
/// then resolves local-first against `registry`, and a terminal miss reports
/// `unknown_local_form` at `slotPath` (the enclosing kvpair for a keyed slot,
/// the parent form's path for a positional slot). Mirrors the Zig tree path's
/// `Frame.local_form_registry` / `local_form_slot_path` seam (both carriers).
interface LocalFormScope {
  readonly registry: readonly FormSpec[];
  readonly slotPath: readonly string[];
}

function visit(
  schema: Schema,
  registry: CrossRefRegistry,
  node: Node,
  path: readonly string[],
  scopeChain: readonly ScopeFrame[],
  treeScope: ScopeId,
  treeIdx: number,
  diags: Diagnostic[],
  localScope: LocalFormScope | null,
): void {
  switch (node.tag) {
    case 'form': {
      const formNode = node;
      // Slot-local resolution: a bare head in a local-forms slot resolves
      // local-first (a qualified head bypasses locals). Computed once and
      // reused for both head validation and the children's spec lookup.
      let localHit: FormSpec | null = null;
      if (localScope && formNode.namespace === null) {
        for (const lf of localScope.registry) {
          if (lf.name === formNode.head) {
            localHit = lf;
            break;
          }
        }
      }
      const canonical = canonicalize(schema, namespacedHead(formNode));
      let chain = scopeChain;
      if (canonical && registry.scopeOpeners.has(canonical)) {
        chain = [
          ...scopeChain,
          {
            canonical,
            scopeId: lexicalScopeId(treeIdx, formNode.headSpan.start),
          },
        ];
      }
      validateFormHead(
        schema,
        registry,
        formNode,
        path,
        chain,
        treeScope,
        diags,
        localScope,
        localHit,
      );
      // Resolve this form's own spec so its children can consult their
      // KeySpec.localForms (a local hit shadows the global catalog).
      let ownSpec: FormSpec | null = localHit;
      if (!ownSpec) {
        const r = lookupForm(schema, formNode.head, formNode.namespace);
        if (r.kind === 'found') ownSpec = r.value;
      }
      let positionalCount = 0;
      // The active variant while walking the children in order — set the
      // moment the discriminant kvpair selects one, exactly as
      // `validateFormKeys` resolves it. A variant key's `localForms` are in
      // scope only while its variant is active (and after the
      // discriminant): outside that the key is `unknown_key` and puts
      // nothing in scope. Mirrors the Zig tree walker's `Frame.matched_key`
      // (attachment equals acceptance) and the binary walker's inline rule.
      // No overlay leg here — this port has no materialized defaults.
      let activeVariant: Variant | null = null;
      for (const child of formNode.children) {
        if (child.tag === 'kvpair') {
          const kvPath = [...path, child.key];
          const value = child.value;
          let valuePath = kvPath;
          let childScope: LocalFormScope | null = null;
          // The KeySpec this kvpair is accepted under: a common key by name,
          // else the active variant's key by name.
          let matchedKey: KeySpec | null = null;
          if (ownSpec) {
            const commonIdx = ownSpec.keys.findIndex((k) => k.name === child.key);
            if (commonIdx >= 0) {
              matchedKey = ownSpec.keys[commonIdx]!;
              if (ownSpec.discriminantIdx === commonIdx && value.tag === 'symbol') {
                const sym = value.text;
                const selected = (ownSpec.variants ?? []).find((v) => variantSelects(v, sym));
                if (selected) activeVariant = selected;
              }
            } else if (activeVariant) {
              matchedKey = activeVariant.keys.find((vk) => vk.name === child.key) ?? null;
            }
          }
          // `:walk-opaque true` on the accepted key: the value's contents
          // are opaque to the surrounding schema, so the whole child frame
          // is abandoned rather than pushed. The slot's own type check
          // already ran in `validateFormKeys`; what stops is the per-node
          // descent that would otherwise report `unknown_form` for an
          // expression-shaped value. Mirrors `validateOneTree`'s
          // `continue :outer`.
          if (matchedKey?.walkOpaque) continue;
          if (value.tag === 'form') {
            if (value.head.length > 0) valuePath = [...kvPath, value.head];
            // Attach the slot's local registry when the accepted KeySpec
            // carries local forms (slot path = the kvpair's own path).
            if (matchedKey?.localForms && matchedKey.localForms.length > 0) {
              childScope = { registry: matchedKey.localForms, slotPath: kvPath };
            }
          }
          visit(schema, registry, value, valuePath, chain, treeScope, treeIdx, diags, childScope);
        } else {
          let step: string;
          let childScope: LocalFormScope | null = null;
          if (child.tag === 'form' && child.head.length > 0) {
            step = child.head;
            // Positional slot-local resolution: a form-shaped positional child
            // resolves local-first when this form carries `FormSpec.localForms`
            // (slot path = this form's own path). The positional mirror of the
            // kvpair-value attach above; rides independent of the positional
            // variant (`any` / head-set). Mirrors the Zig tree child-push /
            // binary `.positional` seam.
            if (ownSpec && ownSpec.localForms && ownSpec.localForms.length > 0) {
              childScope = { registry: ownSpec.localForms, slotPath: path };
            }
          } else {
            step = String(positionalCount);
          }
          visit(
            schema,
            registry,
            child,
            [...path, step],
            chain,
            treeScope,
            treeIdx,
            diags,
            childScope,
          );
          positionalCount++;
        }
      }
      break;
    }
    case 'vector': {
      let i = 0;
      for (const elem of node.elements) {
        visit(
          schema,
          registry,
          elem,
          [...path, String(i)],
          scopeChain,
          treeScope,
          treeIdx,
          diags,
          null,
        );
        i++;
      }
      break;
    }
    case 'kvpair': {
      visit(schema, registry, node.value, path, scopeChain, treeScope, treeIdx, diags, null);
      break;
    }
    default:
      break;
  }
}

function validateFormHead(
  schema: Schema,
  registry: CrossRefRegistry,
  node: FormNode,
  path: readonly string[],
  scopeChain: readonly ScopeFrame[],
  treeScope: ScopeId,
  diags: Diagnostic[],
  localScope: LocalFormScope | null,
  localHit: FormSpec | null,
): void {
  if (node.head.length === 0) return;

  // 0. Slot-local resolution (additive, local-first), mirroring the Zig
  // `validateFormHead` step 0. Bare heads only — a qualified head bypasses
  // locals and falls through to the global path below (so its terminal miss
  // is `unknown_form`). A local hit shadows the global catalog; a bare miss
  // falls back to the global form lookup (not expr-funcs — the slot is
  // `:type form`); a miss against both is `unknown_local_form` at the slot.
  if (node.namespace === null && localScope) {
    if (localHit) {
      validateFormKeys(schema, registry, localHit, node, path, scopeChain, treeScope, diags);
      return;
    }
    const g = lookupForm(schema, node.head, null);
    if (g.kind === 'found') {
      validateFormKeys(schema, registry, g.value, node, path, scopeChain, treeScope, diags);
      return;
    }
    if (g.kind === 'ambiguous') {
      emitAmbiguous(diags, node.headSpan, path, 'form', node.head, g.plugins);
      return;
    }
    emitUnknownLocalForm(diags, node.headSpan, localScope.slotPath, node.head, localScope.registry);
    return;
  }

  const spec = lookupForm(schema, node.head, node.namespace);
  if (spec.kind === 'found') {
    validateFormKeys(schema, registry, spec.value, node, path, scopeChain, treeScope, diags);
    return;
  }
  if (spec.kind === 'ambiguous') {
    emitAmbiguous(diags, node.headSpan, path, 'form', node.head, spec.plugins);
    return;
  }
  const fn = lookupExprFunc(schema, node.head, node.namespace);
  if (fn.kind === 'found') {
    validateExprCall(schema, registry, fn.value, node, path, scopeChain, treeScope, diags);
    return;
  }
  if (fn.kind === 'ambiguous') {
    emitAmbiguous(diags, node.headSpan, path, 'expression', node.head, fn.plugins);
    return;
  }
  emit(diags, node.headSpan, path, 'unknown_form', `unknown form \`${node.head}\``);
}

/// Mirrors `Validator.zig:emitUnknownLocalForm`. A form value in a
/// local-forms slot whose head matched neither a local form nor — after the
/// additive fallback — any global form. Reported at the slot path; the
/// caller suppresses the generic `unknown_form` for this node.
function emitUnknownLocalForm(
  diags: Diagnostic[],
  span: Span,
  slotPath: readonly string[],
  head: string,
  registry: readonly FormSpec[],
): void {
  const names = registry.map((f) => f.name).join(', ');
  emit(
    diags,
    span,
    slotPath,
    'unknown_local_form',
    `unknown form \`${head}\` in this slot — expected one of [${names}] or a known form`,
  );
}

/// Mirrors `Validator.zig:emitAmbiguous`. Picks the diagnostic code
/// from the `kind` literal so a single helper covers form/expression/
/// value-kind dispatch.
function emitAmbiguous(
  diags: Diagnostic[],
  span: Span,
  path: readonly string[],
  kind: 'form' | 'expression' | 'value-kind',
  head: string,
  plugins: readonly { name: string }[],
): void {
  const code: DiagnosticCode =
    kind === 'expression'
      ? 'ambiguous_expr'
      : kind === 'value-kind'
        ? 'ambiguous_element_kind'
        : 'ambiguous_form';
  const list = plugins.map((p) => p.name).join(', ');
  emit(
    diags,
    span,
    path,
    code,
    `${kind} \`${head}\` is ambiguous — defined by [${list}]; qualify with \`<ns>/${head}\``,
  );
}

// Mirrors `Validator.zig`'s expression-call dispatch. Arity check
// emits at the form-head path (`[fnname]`); kvpair arguments emit
// `expr_kvpair_not_allowed` at `[fnname keyword]`; positional args
// type-check against `params[i]` and emit `expr_type_mismatch` at
// `[fnname argIdx]` when typed and the input is a literal-tagged
// node (symbols / forms defer to runtime evaluation).
function validateExprCall(
  schema: Schema,
  registry: CrossRefRegistry,
  fn: ExprFunc,
  node: FormNode,
  path: readonly string[],
  scopeChain: readonly ScopeFrame[],
  treeScope: ScopeId,
  diags: Diagnostic[],
): void {
  if (!checkArity(fn.arity, node.children.length)) {
    emit(
      diags,
      node.headSpan,
      path,
      'arity_mismatch',
      `expression \`${fn.name}\` ${describeArity(fn)}, got ${node.children.length}`,
    );
  }
  let positionalIdx = 0;
  for (const child of node.children) {
    if (child.tag === 'kvpair') {
      emit(
        diags,
        child.keySpan,
        [...path, child.key],
        'expr_kvpair_not_allowed',
        `expression \`${fn.name}\` does not accept keyword argument \`:${child.key}\``,
      );
      continue;
    }
    // Symbols may resolve to runtime bindings — defer. Forms now
    // route through `matchType`, which uses the form-expression
    // resolver to compare declared results against `paramTypeAt`.
    const checkable = child.tag !== 'symbol';
    if (checkable) {
      const t = paramTypeAt(fn, positionalIdx);
      if (t) {
        const fail = matchType(schema, registry, child, t, scopeChain, treeScope, 0);
        if (fail) {
          emit(
            diags,
            child.span,
            [...path, String(positionalIdx)],
            'expr_type_mismatch',
            `expression \`${fn.name}\` argument ${positionalIdx} expects ${describeType(t)}`,
          );
        }
      }
    }
    positionalIdx++;
  }
}

function describeArity(fn: ExprFunc): string {
  switch (fn.arity.kind) {
    case 'fixed':
      return `expects ${fn.arity.n} argument${fn.arity.n === 1 ? '' : 's'}`;
    case 'at_least':
      return `expects at least ${fn.arity.n} argument${fn.arity.n === 1 ? '' : 's'}`;
    case 'range':
      return `expects ${fn.arity.min}..${fn.arity.max} arguments`;
  }
}

function describeType(t: ValueType): string {
  switch (t.kind) {
    case 'any':
      return 'any value';
    case 'named':
      return t.name;
    default:
      return t.kind;
  }
}

/**
 * The bounded head-set governing `spec`'s positional slot, or null when
 * there is none — every other positional policy, a `.kind` that is not
 * form-underlying or carries no head-set, and (the fast path) a head-set
 * where no entry declares a bound.
 *
 * This is the single place the scope rule from
 * `docs/portable-manifest-v1.md` §4.5 is enforced: counts are read off a
 * form's `:positional` declaration and nowhere else, so the same kind
 * reused on a keyed slot or a `vector-shape :element` carries its bounds
 * inertly. Mirrors Zig's `boundedPositionalHeads`.
 */
function boundedPositionalHeads(schema: Schema, spec: FormSpec): HeadSet | null {
  if (spec.positional.kind !== 'kind') return null;
  const hit = lookupValueKind(schema, spec.positional.name, spec.positional.namespace);
  if (hit.kind !== 'found') return null;
  const vk = hit.value;
  if (vk.underlying !== 'form' || !vk.heads) return null;
  // An empty set narrows nothing, so it counts nothing either — else a
  // `:min-children` floor would demand a child from a set that names none.
  if (vk.heads.heads.length === 0) return null;
  return headSetIsUnbounded(vk.heads) ? null : vk.heads;
}

/**
 * Render a head-set as `[a | b | c]`, in `not_head_member`'s vocabulary.
 * What separates a set-level message from a per-head one — and therefore
 * what makes reusing the two codes the right call. Mirrors Zig's
 * `writeHeadSetList`.
 */
function headSetList(heads: readonly Head[]): string {
  return `[${heads.map((h) => h.name).join(' | ')}]`;
}

/**
 * Tally one positional child and report the child that crosses a `:max`.
 * `head` is empty for a non-form child, which matches no entry and is
 * therefore counted nowhere. The emit fires exactly once — on the
 * transition from `max` to `max + 1` — so a form five children over its
 * ceiling still gets one diagnostic. Mirrors Zig's `tallyPositionalHead`.
 *
 * Both bound levels are judged here, and **the set yields to the head**:
 * `:min-children 1 :max-children 1` over heads each `:max 1` is "exactly
 * one, and not two of the same", so a second `(buffer …)` crosses both
 * ceilings on one child — same span, same path, same code. The per-head
 * report names the line to delete and the set's claim is implied by it.
 */
function tallyPositionalHead(
  diags: Diagnostic[],
  bounds: HeadSet,
  counts: number[],
  formName: string,
  head: string,
  span: Span,
  posPath: readonly string[],
): void {
  if (head.length === 0) return;
  for (let i = 0; i < bounds.heads.length; i++) {
    const h = bounds.heads[i]!;
    if (h.name !== head) continue;
    counts[i] = counts[i]! + 1;
    if (h.max !== undefined && counts[i] === h.max + 1) {
      emit(
        diags,
        span,
        posPath,
        'positional_too_many',
        `form \`${formName}\` accepts at most ${h.max} \`${h.name}\` positional ` +
          `child${h.max === 1 ? '' : 'ren'}, found ${counts[i]}`,
      );
      return;
    }
    // The set half, reached only for a child that matched a head and did
    // not report for it. The running total is Σ counts rather than a
    // counter of its own: a child counts towards the set exactly when it
    // counts towards a head. Mirrors Zig's `tallyPositionalSet`.
    if (bounds.maxChildren === undefined) return;
    const total = counts.reduce((acc, n) => acc + n, 0);
    if (total !== bounds.maxChildren + 1) return;
    emit(
      diags,
      span,
      posPath,
      'positional_too_many',
      `form \`${formName}\` accepts at most ${bounds.maxChildren} positional ` +
        `child${bounds.maxChildren === 1 ? '' : 'ren'} from ${headSetList(bounds.heads)}, ` +
        `found ${total}`,
    );
    return;
  }
}

function validateFormKeys(
  schema: Schema,
  registry: CrossRefRegistry,
  spec: FormSpec,
  node: FormNode,
  path: readonly string[],
  scopeChain: readonly ScopeFrame[],
  treeScope: ScopeId,
  diags: Diagnostic[],
): void {
  const seenKeys = new Set<string>();
  const dupReported = new Set<string>();
  for (const child of node.children) {
    if (child.tag !== 'kvpair') continue;
    if (seenKeys.has(child.key)) {
      if (!dupReported.has(child.key)) {
        emit(
          diags,
          child.keySpan,
          [...path, child.key],
          'duplicate_key',
          `duplicate keyword \`:${child.key}\` in form \`${spec.name}\``,
        );
        dupReported.add(child.key);
      }
    } else {
      seenKeys.add(child.key);
    }
  }

  const seenIdx = new Set<number>();
  // Variant-only keys the author wrote, by index into the *resolved*
  // variant's `keys`. Stays empty while no variant is resolved.
  const seenVariantIdx = new Set<number>();
  const variants = spec.variants ?? [];
  // The active variant, set the moment the discriminant kvpair is matched
  // to a declared `:when`. Null until then — which is exactly what makes a
  // variant-only key written *before* the discriminant fall through to
  // `unknown_key`. That position rule is the schema's, not an artifact:
  // both Zig walkers apply it, so producers emit the discriminant first.
  let resolvedWhen: string | null = null;
  let resolvedVariantIdx: number | null = null;

  /** Type-check one kvpair value against the slot it landed in, and run the
   *  advisory sweep on success. Shared by the declared-key and variant-key
   *  arms, which differ only in where the spec came from. */
  const checkKvpairValue = (child: KvPairNode, valueType: ValueType): void => {
    const fail = matchType(schema, registry, child.value, valueType, scopeChain, treeScope, 0);
    if (fail) {
      emit(
        diags,
        fail.span ?? child.value.span,
        [...path, child.key],
        fail.code,
        fail.message(spec.name, child.key),
      );
    } else {
      emitValueAdvisories(diags, schema, registry, valueType, child.value, scopeChain, treeScope, [
        ...path,
        child.key,
      ]);
    }
  };

  // Positional ordinal (mirrors Zig's `positional_n`) and the per-form
  // set of already-seen flag names (mirrors Zig's `seen_flags`).
  let posIndex = 0;
  const seenFlags = new Set<string>();
  // Per-head positional tallies (mirrors Zig's `pos_head_counts`).
  // Resolved once per form; null for every unbounded head-set, which is
  // the fast path the compact `:names [a b c]` spelling always takes.
  const posBounds = boundedPositionalHeads(schema, spec);
  const posCounts: number[] = posBounds ? posBounds.heads.map(() => 0) : [];
  for (const child of node.children) {
    if (child.tag === 'kvpair') {
      const matchIdx = spec.keys.findIndex((k) => k.name === child.key);
      if (matchIdx >= 0) {
        seenIdx.add(matchIdx);
        const k = spec.keys[matchIdx]!;
        checkKvpairValue(child, k.valueType);
        // Discriminant slot: capture the author-written variant. The type
        // check above already emitted `not_member` for a value outside the
        // enum, so such a value leaves the variant unresolved rather than
        // selecting a branch on a name the schema does not admit.
        if (spec.discriminantIdx === matchIdx && child.value.tag === 'symbol') {
          const sym = child.value.text;
          const vi = variants.findIndex((v) => variantSelects(v, sym));
          if (vi >= 0) {
            resolvedWhen = variantWhenText(variants[vi]!.when);
            resolvedVariantIdx = vi;
          }
        }
        continue;
      }
      // Variant-key fallthrough — only reachable once the discriminant has
      // resolved.
      const activeVariant = resolvedVariantIdx === null ? null : variants[resolvedVariantIdx]!;
      const variantIdx = activeVariant
        ? activeVariant.keys.findIndex((vk) => vk.name === child.key)
        : -1;
      if (activeVariant && variantIdx >= 0) {
        seenVariantIdx.add(variantIdx);
        checkKvpairValue(child, activeVariant.keys[variantIdx]!.valueType);
      } else if (!spec.open) {
        emit(
          diags,
          child.keySpan,
          [...path, child.key],
          'unknown_key',
          unknownKeywordMessage(spec, child.key, resolvedWhen),
        );
      }
    } else {
      // Form children step by head; others by positional index. Mirrors
      // Zig's `positionalStep` so paths line up across hosts.
      const step = child.tag === 'form' && child.head.length > 0 ? child.head : String(posIndex);
      switch (spec.positional.kind) {
        case 'none':
          if (!spec.open) {
            // A keyword leaf here is a keyword the parser could not pair,
            // which reads nothing like a positional to an author. Mirrors
            // Zig's `positionalNotAllowedMsg`; the path step is unchanged.
            const bareKeyword = child.tag === 'keyword' ? child.name : null;
            emit(
              diags,
              child.span,
              [...path, step],
              'positional_not_allowed',
              bareKeyword === null
                ? `form \`${spec.name}\` does not accept positional children`
                : `form \`${spec.name}\` does not accept positional children — \`:${bareKeyword}\` has no value, so it is a bare keyword, not a keyword pair`,
            );
          }
          break;
        case 'any':
          break;
        case 'kind': {
          // Tally before the type check, and off the child's own head
          // rather than the match outcome: a head outside the set fails
          // `not_head_member` below and matches no entry here, so it
          // counts towards nothing. Same reading order as both Zig
          // walkers.
          if (posBounds) {
            const childHead = child.tag === 'form' ? child.head : '';
            tallyPositionalHead(diags, posBounds, posCounts, spec.name, childHead, child.span, [
              ...path,
              step,
            ]);
          }
          const fail = matchType(
            schema,
            registry,
            child,
            { kind: 'named', name: spec.positional.name, namespace: spec.positional.namespace },
            scopeChain,
            treeScope,
            0,
          );
          if (fail) {
            emit(
              diags,
              fail.span ?? child.span,
              [...path, step],
              fail.code,
              fail.message(spec.name, '<positional>'),
            );
          } else {
            // The whole advisory family, as at every keyed site. This slot
            // used to carry only the string-pattern half — the same drift
            // the Zig walker had, and the reason both hosts now bundle.
            emitValueAdvisories(
              diags,
              schema,
              registry,
              { kind: 'named', name: spec.positional.name, namespace: spec.positional.namespace },
              child,
              scopeChain,
              treeScope,
              [...path, step],
            );
          }
          break;
        }
        case 'flag_set': {
          if (child.tag !== 'keyword') {
            emit(
              diags,
              child.span,
              [...path, step],
              'wrong_underlying',
              `form \`${spec.name}\` accepts only positional keyword flags here, not a value`,
            );
          } else if (!spec.positional.flags.some((f) => f.name === child.name)) {
            // `child.name` is colon-stripped by the parser, matching the
            // bare flag names — compare directly (metadata is ignored).
            emit(
              diags,
              child.span,
              [...path, step],
              'not_flag_member',
              `positional flag \`:${child.name}\` is not declared on form \`${spec.name}\` (declared flags: ${spec.positional.flags
                .map((f) => ':' + f.name)
                .join(', ')})`,
            );
          } else if (seenFlags.has(child.name)) {
            // A valid flag repeated on this form (mirrors Zig's seen_flags).
            emit(
              diags,
              child.span,
              [...path, step],
              'duplicate_positional_flag',
              `positional flag \`:${child.name}\` is repeated on form \`${spec.name}\``,
            );
          } else {
            seenFlags.add(child.name);
          }
          break;
        }
      }
      posIndex++;
    }
  }

  // The `:min` sweep, on the near side of the `open` short-circuit below
  // and the only end-of-form sweep that is. Every other one is about
  // *keywords*, which is the surface `:open` widens; a positional count
  // is a different surface, and `:positional <bounded-kind>` opts into
  // it. Mirrors `validateFormKeys` phase 3b in the reference walker.
  if (posBounds) {
    let anyHeadReported = false;
    let total = 0;
    for (let i = 0; i < posBounds.heads.length; i++) {
      const h = posBounds.heads[i]!;
      const min = h.min ?? 0;
      const n = posCounts[i]!;
      total += n;
      if (min === 0 || n >= min) continue;
      anyHeadReported = true;
      emit(
        diags,
        node.headSpan,
        path,
        'positional_missing',
        `form \`${spec.name}\` requires at least ${min} \`${h.name}\` positional ` +
          `child${min === 1 ? '' : 'ren'}, found ${n}`,
      );
    }
    // The set's own floor, and it yields to the head for the same reason
    // the ceiling does: under `:min-children 2` with a head `:min 1`, an
    // empty form breaches both and "add a `buffer`" is the more
    // actionable of the two. Mirrors Zig's `emitPositionalMissing`.
    const setMin = posBounds.minChildren ?? 0;
    if (!anyHeadReported && setMin > 0 && total < setMin) {
      emit(
        diags,
        node.headSpan,
        path,
        'positional_missing',
        `form \`${spec.name}\` requires at least ${setMin} positional ` +
          `child${setMin === 1 ? '' : 'ren'} from ${headSetList(posBounds.heads)}, ` +
          `found ${total}`,
      );
    }
  }

  // Everything below enforces closed-form *shape*; type checks above always
  // run, so an open form still gets typed values in its declared slots.
  if (spec.open) return;

  // A discriminated form with no discriminant supplied gets exactly one
  // diagnostic, not a pile of missing-variant-key ones: no variant could be
  // selected, and that is the thing to fix.
  const didx = spec.discriminantIdx;
  if (didx !== undefined && !seenIdx.has(didx)) {
    const dname = spec.discriminantName ?? spec.keys[didx]?.name ?? 'kind';
    emit(
      diags,
      node.headSpan,
      path,
      'missing_discriminant_key',
      `form \`${spec.name}\` is missing required discriminant \`:${dname}\``,
    );
  }

  const groups = spec.exclusiveGroups ?? [];
  for (let ki = 0; ki < spec.keys.length; ki++) {
    const k = spec.keys[ki]!;
    // A defaulted key is effectively optional — the default fills the slot,
    // so its absence is not `missing_required_key` (mirrors the Zig
    // validator's `effectiveOptional` gate in both tree + binary paths).
    if (effectiveOptional(k)) continue;
    if (seenIdx.has(ki)) continue;
    // The discriminant slot is covered by the emit above.
    if (ki === didx) continue;
    // A grouped key's presence is the group sweep's business — "one of
    // these" is not "this one is missing".
    if (keyInExclusiveGroup(groups, k.name)) continue;
    emit(
      diags,
      node.headSpan,
      path,
      'missing_required_key',
      `form \`${spec.name}\` is missing required keyword \`:${k.name}\``,
    );
  }

  emitExclusiveGroupDiagnostics(
    diags,
    groups,
    spec.keys,
    seenIdx,
    spec.name,
    null,
    node.headSpan,
    path,
  );

  emitDependentKeyDiagnostics(
    diags,
    spec.keys,
    seenIdx,
    null,
    null,
    spec.name,
    null,
    node.headSpan,
    path,
  );

  // Variant-only required sweep. Skips a key the author *did* write but
  // which landed as `unknown_key` for preceding the discriminant — they
  // wrote it, just in the wrong order, and the ordering diagnostic is the
  // one to act on.
  if (resolvedVariantIdx !== null) {
    const v = variants[resolvedVariantIdx]!;
    const variantGroups = v.exclusiveGroups ?? [];
    // The active variant's `:when` as written — one value bare, a set
    // bracketed — so a single-value variant's messages read as before.
    const whenText = variantWhenText(v.when);
    for (let vki = 0; vki < v.keys.length; vki++) {
      const vk = v.keys[vki]!;
      if (effectiveOptional(vk)) continue;
      if (seenVariantIdx.has(vki)) continue;
      if (node.children.some((c) => c.tag === 'kvpair' && c.key === vk.name)) continue;
      if (keyInExclusiveGroup(variantGroups, vk.name)) continue;
      emit(
        diags,
        node.headSpan,
        path,
        'missing_required_key',
        `form \`${spec.name}\` (variant \`:when ${whenText}\`) is missing required keyword \`:${vk.name}\``,
      );
    }
    emitExclusiveGroupDiagnostics(
      diags,
      variantGroups,
      v.keys,
      seenVariantIdx,
      spec.name,
      whenText,
      node.headSpan,
      path,
    );
    // A variant key may require a base key, so the base scope comes along.
    // The reverse is rejected at manifest-load time.
    emitDependentKeyDiagnostics(
      diags,
      v.keys,
      seenVariantIdx,
      spec.keys,
      seenIdx,
      spec.name,
      whenText,
      node.headSpan,
      path,
    );
  }
}

// ─── Key dependencies (`:requires`) ─────────────────────────────────────
//
// Mirrors `emitDependentKeyDiagnostics` in `src/Validator.zig`, minus the
// overlay leg — this port has no materialized-defaults machinery, matching
// how it handles exclusive groups.
//
// One diagnostic per unsatisfied *dependent* key, naming all of its absent
// requirements: a key requiring three absent keys says so once with three
// names, not three times.
function emitDependentKeyDiagnostics(
  diags: Diagnostic[],
  keys: readonly KeySpec[],
  seen: ReadonlySet<number>,
  baseKeys: readonly KeySpec[] | null,
  baseSeen: ReadonlySet<number> | null,
  formName: string,
  variantWhen: string | null,
  span: { start: number; end: number },
  path: readonly string[],
) {
  for (let ki = 0; ki < keys.length; ki++) {
    const k = keys[ki]!;
    const reqs = k.requires;
    if (!reqs || reqs.length === 0) continue;
    if (!seen.has(ki)) continue;

    const missing = reqs.filter((req) => {
      if (requirementPresent(req, keys, seen)) return false;
      if (baseKeys && baseSeen && requirementPresent(req, baseKeys, baseSeen)) return false;
      return true;
    });
    if (missing.length === 0) continue;

    const scope = variantWhen === null ? '' : `variant \`${variantWhen}\` `;
    const names = missing.map((m) => `\`:${m}\``).join(', ');
    const tail = missing.length === 1 ? 'which is absent' : 'which are absent';
    emit(
      diags,
      span,
      path,
      'dependent_key_missing',
      `form \`${formName}\` ${scope}keyword \`:${k.name}\` requires ${names}, ${tail}`,
    );
  }
}

function requirementPresent(
  name: string,
  keys: readonly KeySpec[],
  seen: ReadonlySet<number>,
): boolean {
  for (let i = 0; i < keys.length; i++) {
    if (keys[i]!.name === name) return seen.has(i);
  }
  return false;
}

// ─── Exclusive groups ───────────────────────────────────────────────────
//
// Mirrors `emitExclusiveGroupDiagnostics` and its three `alternative*`
// predicates in `src/Validator.zig`, minus the overlay leg: without the
// default-materialization overlay this host has no *defaulted* alternative,
// so `default_count` is structurally zero and
// `multiple_defaulted_alternatives_in_group` — which fires only when two
// alternatives are satisfied by defaults alone — cannot arise here. That is
// the one exclusive-group code the wasm-backed hosts can emit and this one
// cannot, and it is an axis-C code, already outside this port's scope.

/** True when `name` appears in any alternative of any group. Both required-key
 *  sweeps use it to stand down: the group sweep owns presence diagnostics for
 *  grouped keys, and two reports of the same absence read as two problems. */
function keyInExclusiveGroup(groups: readonly ExclusiveGroup[], name: string): boolean {
  return groups.some((g) => g.alternatives.some((alt) => alt.keys.includes(name)));
}

/** True when every key in `alt` is present. An alt key with no slot in `keys`
 *  counts as absent — the loader rejects that shape, so reaching here means a
 *  hand-built spec, and treating the unknown name as present would invent a
 *  satisfied alternative. */
function alternativePresent(
  alt: Alternative,
  keys: readonly KeySpec[],
  seen: ReadonlySet<number>,
): boolean {
  if (alt.keys.length === 0) return false;
  return alt.keys.every((kn) => {
    const idx = keys.findIndex((k) => k.name === kn);
    return idx >= 0 && seen.has(idx);
  });
}

/** True when a multi-key bundle is partly present: at least one key set, at
 *  least one absent. Single-key alts never report partial — a bundle is what
 *  can be half-written. */
function alternativePartiallyPresent(
  alt: Alternative,
  keys: readonly KeySpec[],
  seen: ReadonlySet<number>,
): boolean {
  if (alt.keys.length <= 1) return false;
  let anySet = false;
  let anyAbsent = false;
  for (const kn of alt.keys) {
    const idx = keys.findIndex((k) => k.name === kn);
    if (idx >= 0 && seen.has(idx)) anySet = true;
    else anyAbsent = true;
  }
  return anySet && anyAbsent;
}

function emitExclusiveGroupDiagnostics(
  diags: Diagnostic[],
  groups: readonly ExclusiveGroup[],
  keys: readonly KeySpec[],
  seen: ReadonlySet<number>,
  formName: string,
  variantWhen: string | null,
  span: Span,
  path: readonly string[],
): void {
  for (const group of groups) {
    const presentCount = group.alternatives.filter((alt) =>
      alternativePresent(alt, keys, seen),
    ).length;

    if (presentCount >= 2) {
      emit(
        diags,
        span,
        path,
        'mutually_exclusive_keys_present',
        exclusiveGroupMessage(formName, variantWhen, group, 'mutually_exclusive_keys_present'),
      );
      continue;
    }

    // Partial bundles fire only when no sibling alt is fully present: a full
    // sibling already won the group above, and a partial next to a satisfied
    // sibling is just overspecification, not a broken bundle.
    if (presentCount > 0) continue;

    let anyPartial = false;
    for (const alt of group.alternatives) {
      if (!alternativePartiallyPresent(alt, keys, seen)) continue;
      anyPartial = true;
      emit(
        diags,
        span,
        path,
        'exclusive_bundle_partial',
        exclusiveBundleMessage(formName, variantWhen, alt, keys, seen),
      );
    }

    // A partial bundle suppresses `required_one_of_missing`: the author did
    // pick an alternative, so naming its missing siblings beats telling them
    // they picked none.
    if (!anyPartial && group.cardinality === 'exactly_one') {
      emit(
        diags,
        span,
        path,
        'required_one_of_missing',
        exclusiveGroupMessage(formName, variantWhen, group, 'required_one_of_missing'),
      );
    }
  }
}

/** `:k1` / `:k1+:k2` bundles joined by ` | ` — readable for both the v1
 *  single-key shape and multi-key bundles. */
function renderAlternatives(group: ExclusiveGroup): string {
  return group.alternatives.map((alt) => alt.keys.map((k) => `:${k}`).join('+')).join(' | ');
}

function exclusiveGroupMessage(
  formName: string,
  variantWhen: string | null,
  group: ExclusiveGroup,
  code: 'mutually_exclusive_keys_present' | 'required_one_of_missing',
): string {
  const scope = variantWhen === null ? '' : ` (variant \`:when ${variantWhen}\`)`;
  const [lead, tail] =
    code === 'mutually_exclusive_keys_present'
      ? [': at most one of ', ' may be present']
      : [': exactly one of ', ' must be present'];
  return `form \`${formName}\`${scope}${lead}${renderAlternatives(group)}${tail}`;
}

/** Names every key in the bundle, tagged set/missing, so the author can see
 *  which sibling to add. */
function exclusiveBundleMessage(
  formName: string,
  variantWhen: string | null,
  alt: Alternative,
  keys: readonly KeySpec[],
  seen: ReadonlySet<number>,
): string {
  const scope = variantWhen === null ? '' : ` (variant \`:when ${variantWhen}\`)`;
  const bundle = alt.keys.map((k) => `:${k}`).join('+');
  const detail = alt.keys
    .map((kn) => {
      const idx = keys.findIndex((k) => k.name === kn);
      return `:${kn}${idx >= 0 && seen.has(idx) ? ' set' : ' missing'}`;
    })
    .join(', ');
  return `form \`${formName}\`${scope}: exclusive-group alt \`${bundle}\` is partially present (${detail}); bundles are all-or-nothing`;
}

/**
 * Prose for `unknown_key`, in the two shapes the Zig walkers use. A
 * discriminated form whose discriminant has *not* resolved gets the ordering
 * hint — on such a form the likeliest cause of an unknown key is a
 * variant-only key written too early, and the plain message would send the
 * author looking for a typo instead. Otherwise the message is plain,
 * annotated with the active variant when there is one. Mirrors
 * `unknownKeywordMsg` + `UnknownKeyContext` in `src/Validator.zig`.
 */
function unknownKeywordMessage(spec: FormSpec, key: string, resolvedWhen: string | null): string {
  if (spec.discriminantIdx !== undefined && resolvedWhen === null) {
    const dname = spec.discriminantName ?? 'kind';
    return `unknown keyword \`:${key}\` in form \`${spec.name}\` — \`:${dname}\` must be set before variant-only keys`;
  }
  const suffix = resolvedWhen === null ? '' : ` (variant \`:when ${resolvedWhen}\`)`;
  return `unknown keyword \`:${key}\` in form \`${spec.name}\`${suffix}`;
}

interface MatchFail {
  readonly code: DiagnosticCode;
  message(formName: string, slot: string): string;
  // Where the diagnostic points, when that is not the slot's own value.
  // Set only by `wrapElementFail`: a typed-vector element failure carries
  // the outer slot's label and path but spans the element that is actually
  // wrong. Mirrors `Validator.zig`'s `failLeaf`.
  readonly span?: Span;
}

function matchType(
  schema: Schema,
  registry: CrossRefRegistry,
  node: Node,
  expected: ValueType,
  scopeChain: readonly ScopeFrame[],
  treeScope: ScopeId,
  depth: number,
): MatchFail | null {
  // A *held* position matches whatever the slot declares. One gate here
  // covers every position a value can occupy and every refinement axis,
  // because this function is the single door to typed matching: kvpair
  // values, positional children, vector elements and union alternatives all
  // arrive here. Held-ness is a property of the value, not the slot — the
  // moment the author replaces `_` with a real value the full check runs
  // again. Mirrors the gate at the top of `matchValueAgainstType`.
  if (isHeld(registry, node)) return null;

  // Form values dispatch through the form-expression resolver: data
  // forms in non-form slots are mismatches; expressions with a
  // declared result type are compared; opaque/unresolved expressions
  // defer. Mirrors `matchValueAgainstType` in `src/Validator.zig`.
  if (node.tag === 'form' && expected.kind !== 'named') {
    return checkFormInTypedSlot(schema, node, expected);
  }
  switch (expected.kind) {
    case 'any':
      return null;
    case 'number':
      return node.tag === 'number' ? null : wrongUnderlying('number');
    case 'string':
      return node.tag === 'string' ? null : wrongUnderlying('string');
    case 'symbol':
      return node.tag === 'symbol' ? null : wrongUnderlying('symbol');
    case 'boolean':
      return node.tag === 'boolean' ? null : wrongUnderlying('boolean');
    case 'nil':
      return node.tag === 'nil' ? null : wrongUnderlying('nil');
    case 'vector':
      return node.tag === 'vector' ? null : wrongUnderlying('vector');
    case 'form':
    case 'expr':
      return node.tag === 'form' ? null : wrongUnderlying('form');
    case 'named':
      return matchNamed(
        schema,
        registry,
        node,
        expected.name,
        expected.namespace,
        scopeChain,
        treeScope,
        depth,
      );
  }
}

function matchNamed(
  schema: Schema,
  registry: CrossRefRegistry,
  node: Node,
  name: string,
  namespace: string | null,
  scopeChain: readonly ScopeFrame[],
  treeScope: ScopeId,
  depth: number,
): MatchFail | null {
  switch (name) {
    case 'any':
      return null;
    case 'number':
    case 'string':
    case 'symbol':
    case 'boolean':
    case 'nil':
    case 'vector':
    case 'form':
      // Primitive shortcut — same depth, no chain hop.
      return matchType(
        schema,
        registry,
        node,
        { kind: name } as ValueType,
        scopeChain,
        treeScope,
        depth,
      );
  }
  const kind = lookupValueKind(schema, name, namespace);
  if (kind.kind === 'not_found') {
    const display = namespace ? `${namespace}/${name}` : name;
    return {
      code: 'unknown_element_kind',
      message: () => `unknown value-kind \`${display}\``,
    };
  }
  if (kind.kind === 'ambiguous') {
    const list = kind.plugins.map((p) => p.name).join(', ');
    return {
      code: 'ambiguous_element_kind',
      message: () =>
        `value-kind \`${name}\` is ambiguous — defined by [${list}]; qualify with \`<ns>/${name}\``,
    };
  }
  // Chain hop: each named-kind resolution increments depth. Mirrors
  // `MAX_KIND_DEPTH` enforcement in `Validator.zig` matchValueAgainstType
  // — the bound fires before recursion bottoms out, so a self-vectoring
  // kind reports `recursion_depth` at the slot path instead of an
  // `wrong_underlying` leaf far below.
  const nextDepth = depth + 1;
  if (nextDepth >= MAX_KIND_DEPTH) {
    return {
      code: 'recursion_depth',
      message: () => 'value kind chain too deep',
    };
  }
  return matchKind(schema, registry, node, kind.value, scopeChain, treeScope, nextDepth);
}

function matchKind(
  schema: Schema,
  registry: CrossRefRegistry,
  node: Node,
  kind: ValueKind,
  scopeChain: readonly ScopeFrame[],
  treeScope: ScopeId,
  depth: number,
): MatchFail | null {
  // Form values reaching a named kind: defer the structural HeadSet
  // check to the `.form` underlying branch below; a `union_of` kind falls
  // through to the union arm so the form can be dispatched against each
  // alternative (a form-head-set alternative can accept it) — parity with
  // the Zig validator's matchFormAgainstTypeBinary / tree union-over-forms
  // path. Every other underlying dispatches through the form-expression
  // resolver so refined-named primitives (vec3-like kinds) reject coarse
  // expression results consistently.
  if (node.tag === 'form' && kind.underlying !== 'form' && kind.underlying !== 'union_of') {
    return checkFormInTypedSlot(schema, node, { kind: 'named', name: kind.name, namespace: null });
  }
  switch (kind.underlying) {
    case 'number':
      if (node.tag !== 'number') return wrongUnderlying('number');
      if (kind.unit) {
        if (node.unit === undefined) {
          if (kind.unit.required) return unitRequired(kind.unit.allowed);
        } else if (kind.unit.reject) {
          // `:reject` forbids any unit — checked before the allowed-list
          // narrowing (parity with the Zig validator's number_with_unit arm).
          return unitForbidden(node.unit);
        } else if (kind.unit.allowed.length > 0 && !kind.unit.allowed.includes(node.unit)) {
          return unitNotAllowed(node.unit, kind.unit.allowed);
        }
      }
      if (kind.numeric) {
        const fail = checkNumericBounds(node, kind.numeric);
        if (fail) return fail;
      }
      // Repr narrowing is orthogonal to :numeric — both may be set and
      // each is checked independently (parity with the Zig .number arm).
      if (kind.repr) {
        const fail = checkReprValue(node, kind.repr);
        if (fail) return fail;
      }
      return null;
    case 'string':
      if (node.tag !== 'string') return wrongUnderlying('string');
      if (kind.members && !kind.members.some((m) => m.name === node.value)) {
        return notMember(node.value, kind.members);
      }
      if (kind.stringBounds) {
        const fail = checkStringBoundsValue(node.value, kind.stringBounds);
        if (fail) return fail;
      }
      return null;
    case 'symbol':
      if (node.tag !== 'symbol') {
        // Digit-leading escape. A member spelled `1d` / `2d` cannot arrive
        // as a symbol — the lexer reads it as a unit-bearing number — so a
        // kind that declares one genuinely accepts that shape here.
        // Gated as in `matchScalar`: unit-bearing numbers only, only when
        // the kind declares such a member, never on a cross-ref slot
        // (whose member set comes from document symbols under
        // `:name-key`, which cannot be digit-leading).
        if (
          node.tag === 'number' &&
          node.unit !== undefined &&
          kind.crossRef === undefined &&
          kind.members?.some((m) => m.numericSpelling !== undefined)
        ) {
          const key = spellingKeyOf(node.value);
          if (
            key !== undefined &&
            kind.members.some(
              (m) => m.numericSpelling?.value === key && m.numericSpelling.unit === node.unit,
            )
          ) {
            return null;
          }
          // The slot really does accept unit-bearing numbers here, so
          // "`5px` is not one of [1d | 2d | 3d]" beats "a number is not a
          // symbol".
          const shown =
            key === undefined ? `${node.value}${node.unit}` : canonicalSpelling(key, node.unit);
          return notMember(shown, kind.members);
        }
        return wrongUnderlying('symbol');
      }
      if (kind.crossRef) {
        const targetSpec = registry.targetsByKind.get(kind.name);
        if (!targetSpec) return null; // schema-level miss handled elsewhere
        let scopeId: ScopeId;
        if (targetSpec.scopeForm) {
          const found = findNearestScope(scopeChain, targetSpec.scopeForm);
          if (found === null) return outsideScope(node.text, targetSpec.scopeForm);
          scopeId = found;
        } else {
          scopeId = treeScope;
        }
        const scopeMap = registry.byScope.get(scopeId);
        const set = scopeMap?.get(targetSpec.canonicalTarget);
        if (!set || !set.has(node.text)) {
          return notCrossRef(node.text, describeBucket(targetSpec.canonicalTarget).text);
        }
        return null;
      }
      if (kind.members && !kind.members.some((m) => m.name === node.text)) {
        return notMember(node.text, kind.members);
      }
      return null;
    case 'vector':
      if (node.tag !== 'vector') return wrongUnderlying('vector');
      if (kind.vector) {
        const elements = node.elements;
        if (kind.vector.len !== undefined && elements.length !== kind.vector.len) {
          return vectorLengthMismatch(kind.vector.len, elements.length);
        }
        if (kind.vector.minLen !== undefined && elements.length < kind.vector.minLen) {
          return vectorTooShort(elements.length, kind.vector.minLen);
        }
        if (kind.vector.maxLen !== undefined && elements.length > kind.vector.maxLen) {
          return vectorTooLong(elements.length, kind.vector.maxLen);
        }
        if (kind.vector.element) {
          const elemType: ValueType = {
            kind: 'named',
            name: kind.vector.element.name,
            namespace: kind.vector.element.namespace,
          };
          for (let i = 0; i < elements.length; i++) {
            const elem = elements[i]!;
            const fail = matchType(schema, registry, elem, elemType, scopeChain, treeScope, depth);
            if (fail) return wrapElementFail(i, fail, elem);
          }
        }
      }
      return null;
    case 'form':
      if (node.tag !== 'form') return wrongUnderlying('form');
      // An empty closed set is "no narrowing", not "reject everything" —
      // the contract `MemberSet` states and `matchScalar` honours. Both
      // spellings are `invalid_manifest` at load, so this only governs a
      // hand-built schema; the point is that the two sibling constructs
      // answer it the same way, on every host. Mirrors Zig.
      if (
        kind.heads &&
        kind.heads.heads.length > 0 &&
        !kind.heads.heads.some((h) => h.name === node.head)
      ) {
        return notHeadMember(node.head, kind.heads.heads);
      }
      return null;
    case 'union_of': {
      const us = kind.unionOf;
      if (!us) return null;
      // First-match dispatch: the first alternative that accepts wins.
      // When none does, the value is rejected (parity with the Zig
      // validator's union arm — the previous stub accepted everything,
      // which was dead code until `scalar-or-ref` made unions loadable).
      // A union whose alternatives are disjoint by node shape has a
      // determined arm even then (see `determinedArm`); its failure is
      // what gets reported.
      const arm = determinedArm(schema, kind, shapeOfNode(node));
      let armFail: MatchFail | null = null;
      for (let ai = 0; ai < us.alternatives.length; ai++) {
        const alt = us.alternatives[ai]!;
        const fail = matchType(
          schema,
          registry,
          node,
          { kind: 'named', name: alt.name, namespace: alt.namespace },
          scopeChain,
          treeScope,
          depth,
        );
        if (!fail) return null;
        if (arm === ai) armFail = fail;
      }
      return armFail ?? unionNoBranchMatched(node, us.alternatives);
    }
  }
}

/** The shape axis a union arm is selected on. Coarser than the node tag on
 *  purpose — it is the projection the Zig tree and binary walkers agree on
 *  (`Validator.NodeShape`), so this port answers as they do. */
type NodeShape = 'number' | 'string' | 'symbol' | 'vector' | 'form' | 'other';

function shapeOfNode(node: Node): NodeShape {
  switch (node.tag) {
    case 'number':
    case 'string':
    case 'symbol':
    case 'vector':
    case 'form':
      return node.tag;
    default:
      return 'other';
  }
}

/** True when a value of `shape` can reach `alt` at all — when `alt` resolves
 *  to an underlying whose slot admits that shape *before* any refinement
 *  (bounds, members, cross-ref, head-set) is asked. `any` reaches
 *  everything; a nested union and an unresolvable name reach nothing.
 *  Mirrors `alternativeReaches` in `src/Validator.zig`. */
function alternativeReaches(schema: Schema, alt: QualifiedRef, shape: NodeShape): boolean {
  const prim = PRIMITIVE_NORMALIZE.get(alt.name);
  if (prim !== undefined) {
    switch (prim) {
      case 'any':
        return true;
      case 'number':
      case 'string':
      case 'symbol':
      case 'vector':
        return shape === prim;
      case 'form':
      case 'expr':
        return shape === 'form';
      default:
        return false;
    }
  }
  const lookup = lookupValueKind(schema, alt.name, alt.namespace);
  if (lookup.kind !== 'found') return false;
  switch (lookup.value.underlying) {
    case 'number':
    case 'string':
    case 'symbol':
    case 'vector':
    case 'form':
      return shape === lookup.value.underlying;
    default:
      return false;
  }
}

/** The one alternative a node of `shape` could have meant, as an index into
 *  `kind.unionOf.alternatives` — or null when the shape reaches no
 *  alternative, or more than one. Matching is unchanged by this: alternatives
 *  are tried in declaration order and the first to accept wins. It decides
 *  only what a *failure* says — with exactly one reachable arm, nothing else
 *  could have been meant, so that arm's own failure (the bound that refused,
 *  the reference that names nothing) is the actionable one. Zero reachable (a
 *  string against `number | symbol`) or two (a symbol against
 *  `member-set | cross-ref`) keeps `union_no_branch_matched`. The rule stops
 *  at the node shape and does not look through refinements, so two form kinds
 *  with disjoint head-sets keep the collapse. Mirrors `determinedArm` in
 *  `src/Validator.zig`. */
function determinedArm(schema: Schema, kind: ValueKind, shape: NodeShape): number | null {
  if (!kind.unionOf) return null;
  let only: number | null = null;
  for (let i = 0; i < kind.unionOf.alternatives.length; i++) {
    if (!alternativeReaches(schema, kind.unionOf.alternatives[i]!, shape)) continue;
    if (only !== null) return null; // two reach: overlap, no arm to blame
    only = i;
  }
  return only;
}

function wrongUnderlying(expected: string): MatchFail {
  return {
    code: 'wrong_underlying',
    message: (formName, slot) => `form \`${formName}\` keyword \`:${slot}\` expects ${expected}`,
  };
}

function unionNoBranchMatched(node: Node, alternatives: readonly QualifiedRef[]): MatchFail {
  const list = alternatives
    .map((a) => `\`${a.namespace ? `${a.namespace}/${a.name}` : a.name}\``)
    .join(' | ');
  return {
    code: 'union_no_branch_matched',
    message: () => `got ${node.tag} (no alternative matched: ${list})`,
  };
}

function notMember(got: string, allowed: readonly Member[]): MatchFail {
  return {
    code: 'not_member',
    message: () => `value \`${got}\` is not in [${allowed.map((m) => m.name).join(', ')}]`,
  };
}

/// The canonical member spelling for a unit-bearing literal, or null when
/// its magnitude cannot be one. Mirrors `canonicalMemberSpelling` in
/// src/Validator.zig.
function numericMemberText(magnitude: number, unit: string): string | null {
  const key = spellingKeyOf(magnitude);
  if (key === undefined) return null;
  return canonicalSpelling(key, unit);
}

/// After a successful symbol/string match against a typed slot, emit a
/// `deprecated_member` warning when the matched member carries
/// `deprecated: true`. No-op when the slot's expected type isn't a
/// member-set kind, or when the value didn't match any member (the
/// caller already gates on success). Mirrors
/// `emitDeprecatedMemberCore` in src/Validator.zig.
function emitDeprecatedMember(
  diags: Diagnostic[],
  schema: Schema,
  expected: ValueType,
  value: Node,
  path: readonly string[],
): void {
  if (expected.kind !== 'named') return;
  const lookup = lookupValueKind(schema, expected.name, expected.namespace);
  if (lookup.kind !== 'found') return;
  const kind = lookup.value;
  if (!kind.members || kind.members.length === 0) return;
  // A digit-leading member matched numerically supplies no symbol text,
  // so render the canonical spelling — which is exactly what the loader
  // stored as `Member.name`. Without this a deprecated `2d` would match
  // silently. Mirrors the tree wrapper's `.number_with_unit` arm in Zig.
  const text =
    value.tag === 'symbol'
      ? value.text
      : value.tag === 'string'
        ? value.value
        : value.tag === 'number' && value.unit !== undefined
          ? numericMemberText(value.value, value.unit)
          : null;
  if (text === null) return;
  for (const m of kind.members) {
    if (m.name !== text) continue;
    if (!m.deprecated) return;
    let message = `member \`${m.name}\` is deprecated`;
    if (m.deprecationMessage && m.deprecationMessage.length > 0) {
      message += `: ${m.deprecationMessage}`;
    }
    diags.push({
      code: 'deprecated_member',
      message,
      path: [...path],
      span: value.span,
      severity: 'warning',
    });
    return;
  }
}

/// Emit `string_pattern_unsupported` whenever a string value matches
/// against a kind whose `:string-bounds :pattern …` is set. v1 builds
/// carry no regex engine; the constraint is informational only. No
/// dedup in v1 — every value site fires its own warning (the engine
/// milestone may add per-pass dedup). Mirrors
/// `emitStringPatternUnsupportedCore` in src/Validator.zig.
function emitStringPatternUnsupported(
  diags: Diagnostic[],
  schema: Schema,
  expected: ValueType,
  value: Node,
  path: readonly string[],
): void {
  if (expected.kind !== 'named') return;
  if (value.tag !== 'string') return;
  const lookup = lookupValueKind(schema, expected.name, expected.namespace);
  if (lookup.kind !== 'found') return;
  const kind = lookup.value;
  if (kind.underlying !== 'string') return;
  const sb = kind.stringBounds;
  if (!sb || sb.pattern === undefined) return;
  diags.push({
    code: 'string_pattern_unsupported',
    message: `value-kind \`${kind.name}\` declares \`:pattern "${sb.pattern}"\` but this build has no regex engine — constraint is informational only`,
    path: [...path],
    span: value.span,
    severity: 'warning',
  });
}

/// What one union alternative makes of a symbol value, for the ambiguity
/// advisory. Mirrors `AltVerdict` in src/Validator.zig.
type AltVerdict =
  /// Cannot accept this symbol at all.
  | { readonly kind: 'rejects' }
  /// Accepts, but denotes no named entity — a member set, a bare `symbol`,
  /// or `any`. Winning the union with one of these means the slot is not a
  /// reference, so there is nothing to be ambiguous about.
  | { readonly kind: 'accepts_plain' }
  /// Accepts as a reference into the named bucket.
  | { readonly kind: 'accepts_ref'; readonly target: string; readonly scope: ScopeId };

const REJECTS: AltVerdict = { kind: 'rejects' };
const ACCEPTS_PLAIN: AltVerdict = { kind: 'accepts_plain' };

/// Classify one union alternative against a symbol value. Mirrors the
/// acceptance gates of `matchKind`'s `symbol` arm — cross-ref membership,
/// then the member set — and nothing else; every other underlying rejects a
/// symbol outright. Re-derived rather than delegated for the reason the Zig
/// twin gives: this asks the narrower "is the name demonstrably registered
/// in this bucket" and must have no side effects.
///
/// A nested union is rejected at schema-aggregate time (`nested_union`), so
/// the `union_of` case folds into `rejects` rather than recursing.
function classifySymbolAlternative(
  schema: Schema,
  registry: CrossRefRegistry,
  alt: QualifiedRef,
  scopeChain: readonly ScopeFrame[],
  treeScope: ScopeId,
  text: string,
): AltVerdict {
  switch (alt.name) {
    case 'any':
    case 'symbol':
      return ACCEPTS_PLAIN;
    case 'number':
    case 'string':
    case 'boolean':
    case 'nil':
    case 'vector':
    case 'form':
      return REJECTS;
  }
  const lookup = lookupValueKind(schema, alt.name, alt.namespace);
  // Unknown / ambiguous alternatives already have their own diagnostic from
  // the match itself; an advisory does not pile on.
  if (lookup.kind !== 'found') return REJECTS;
  const kind = lookup.value;
  if (kind.underlying !== 'symbol') return REJECTS;
  if (kind.crossRef) {
    const targetSpec = registry.targetsByKind.get(kind.name);
    if (!targetSpec) return REJECTS;
    let scopeId: ScopeId;
    if (targetSpec.scopeForm) {
      const found = findNearestScope(scopeChain, targetSpec.scopeForm);
      if (found === null) return REJECTS;
      scopeId = found;
    } else {
      scopeId = treeScope;
    }
    const set = registry.byScope.get(scopeId)?.get(targetSpec.canonicalTarget);
    if (!set || !set.has(text)) return REJECTS;
    return { kind: 'accepts_ref', target: targetSpec.canonicalTarget, scope: scopeId };
  }
  if (kind.members && kind.members.length > 0) {
    return kind.members.some((m) => m.name === text) ? ACCEPTS_PLAIN : REJECTS;
  }
  return ACCEPTS_PLAIN;
}

/// After a symbol has matched a `:underlying union` slot, warn when two or
/// more of the union's cross-ref-backed alternatives register that name — so
/// which entity the slot denotes is decided by declaration order. Mirrors
/// `emitUnionAmbiguousCore` in src/Validator.zig, including its silences: a
/// plain winner ahead of every reference, and the bucket dedup that keeps
/// two kinds pointing at one target from reading as two entities.
function emitUnionAmbiguous(
  diags: Diagnostic[],
  schema: Schema,
  registry: CrossRefRegistry,
  expected: ValueType,
  value: Node,
  scopeChain: readonly ScopeFrame[],
  treeScope: ScopeId,
  path: readonly string[],
): void {
  if (expected.kind !== 'named') return;
  if (value.tag !== 'symbol') return;
  const lookup = lookupValueKind(schema, expected.name, expected.namespace);
  if (lookup.kind !== 'found') return;
  const kind = lookup.value;
  if (kind.underlying !== 'union_of' || !kind.unionOf) return;

  const claimants: { kindName: string; target: string; scope: ScopeId }[] = [];
  for (const alt of kind.unionOf.alternatives) {
    const verdict = classifySymbolAlternative(
      schema,
      registry,
      alt,
      scopeChain,
      treeScope,
      value.text,
    );
    if (verdict.kind === 'rejects') continue;
    if (verdict.kind === 'accepts_plain') {
      // A plain acceptance ahead of every reference wins the union
      // outright. After a reference has already won it changes nothing.
      if (claimants.length === 0) return;
      continue;
    }
    const seen = claimants.some((c) => c.scope === verdict.scope && c.target === verdict.target);
    if (!seen) claimants.push({ kindName: alt.name, target: verdict.target, scope: verdict.scope });
  }
  if (claimants.length < 2) return;

  const list = claimants
    .map((c, i) => {
      const sep = i === 0 ? '' : i + 1 === claimants.length ? ' and ' : ', ';
      return `${sep}\`${c.kindName}\` (target \`${c.target}\`)`;
    })
    .join('');
  diags.push({
    code: 'union_ambiguous',
    message:
      `symbol \`${value.text}\` resolves in ${claimants.length} alternatives of \`${kind.name}\` — ` +
      `${list}. First match wins; rename one declaration or split the slot.`,
    path: [...path],
    span: value.span,
    severity: 'warning',
  });
}

/// The advisory sweep run on a value that has just matched its slot's
/// declared type. Every member is `warning` severity and none changes the
/// document's verdict. Bundled for the reason the Zig twin gives: they had
/// already drifted apart per-site once, and one call means a new advisory
/// reaches every match site or none. Mirrors `emitValueAdvisoriesTree`.
function emitValueAdvisories(
  diags: Diagnostic[],
  schema: Schema,
  registry: CrossRefRegistry,
  expected: ValueType,
  value: Node,
  scopeChain: readonly ScopeFrame[],
  treeScope: ScopeId,
  path: readonly string[],
): void {
  // `matchType` accepted a held value without reading the slot, so no
  // advisory may read it either: a value the author has not chosen cannot
  // be deprecated and cannot be ambiguous between union arms.
  if (isHeld(registry, value)) return;
  emitDeprecatedMember(diags, schema, expected, value, path);
  emitStringPatternUnsupported(diags, schema, expected, value, path);
  emitUnionAmbiguous(diags, schema, registry, expected, value, scopeChain, treeScope, path);
}

function notHeadMember(got: string, allowed: readonly Head[]): MatchFail {
  return {
    code: 'not_head_member',
    message: () => `head \`${got}\` is not in [${allowed.map((h) => h.name).join(', ')}]`,
  };
}

function vectorTooShort(got: number, minLen: number): MatchFail {
  return {
    code: 'vector_too_short',
    message: (formName, slot) =>
      `form \`${formName}\` keyword \`:${slot}\` expects vector of length ≥ ${minLen}, got ${got}`,
  };
}

function vectorTooLong(got: number, maxLen: number): MatchFail {
  return {
    code: 'vector_too_long',
    message: (formName, slot) =>
      `form \`${formName}\` keyword \`:${slot}\` expects vector of length ≤ ${maxLen}, got ${got}`,
  };
}

function vectorLengthMismatch(want: number, got: number): MatchFail {
  return {
    code: 'vector_length_mismatch',
    message: (formName, slot) =>
      `form \`${formName}\` keyword \`:${slot}\` expects vector of length ${want}, got ${got}`,
  };
}

function unitRequired(allowed: readonly string[]): MatchFail {
  return {
    code: 'unit_required',
    message: () =>
      allowed.length > 0
        ? `got number without unit, expected one of [${allowed.join(', ')}]`
        : 'got number without unit',
  };
}

function unitNotAllowed(got: string, allowed: readonly string[]): MatchFail {
  return {
    code: 'unit_not_allowed',
    message: () => `got number with unit \`${got}\`, expected one of [${allowed.join(', ')}]`,
  };
}

function unitForbidden(got: string): MatchFail {
  return {
    code: 'unit_forbidden',
    message: () => `got number with unit \`${got}\` (slot rejects units — bare number required)`,
  };
}

/// `target` is the rendered bucket (`Schema.describeBucket`), so a
/// multi-target group reads `a | b` and a single target reads its
/// canonical `<plugin>/<form>` name — the same target text the reference
/// host names.
///
/// The surrounding *sentence* still differs from Zig's ``got `x` (no
/// `(y :name …)` form declares this name)``. That is the standing
/// `MatchFail` message-protocol divergence, not this one: closing it means
/// threading the form name and the `:name`-key through every leaf
/// builder, which is a separate plan.
function notCrossRef(got: string, target: string): MatchFail {
  return {
    code: 'not_cross_ref',
    message: () => `\`${got}\` is not a registered name for \`${target}\``,
  };
}

function outsideScope(got: string, scopeForm: string): MatchFail {
  return {
    code: 'cross_ref_outside_scope',
    message: () => `\`${got}\` referenced outside any \`${bareFromCanonical(scopeForm)}\` scope`,
  };
}

/// Wrap an element failure in its index, keeping the outer slot's framing.
/// The span is the *innermost* leaf — `inner.span` when the element was
/// itself a vector whose element failed — so a `mat4` whose row 0 slot 0 is
/// a string points at the string, not at row 0. Mirrors `failLeaf`.
function wrapElementFail(idx: number, inner: MatchFail, elem: Node): MatchFail {
  return {
    code: inner.code,
    message: (formName, slot) => `element [${idx}]: ${inner.message(formName, slot)}`,
    span: inner.span ?? elem.span,
  };
}

/// Tag-true numeric value for the bound check. The TS parser doesn't
/// model `Tag.number_i64` / `Tag.number_u64` separately, but it stashes
/// the literal's exact bigint on `NumberNode.integerBits` whenever the
/// lexeme matched `/^-?\d+$/` and fit i64/u64. The bigint is what lets
/// the bound check compare exactly against an integer-tag bound.
type NumericValue = { kind: 'int'; bits: bigint; f: number } | { kind: 'f64'; f: number };

function readNumericValue(node: NumberNode): NumericValue {
  if (node.integerBits !== undefined) {
    return { kind: 'int', bits: node.integerBits, f: node.value };
  }
  return { kind: 'f64', f: node.value };
}

function valueIsInteger(value: NumericValue): boolean {
  if (value.kind === 'int') return true;
  return Number.isFinite(value.f) && Math.floor(value.f) === value.f;
}

function compareToBound(value: NumericValue, bound: NumericBound): -1 | 0 | 1 {
  // Integer-space comparison when both sides are exact integer literals.
  // Mirrors Zig's `boundFitsI64 / boundFitsU64 + intFromFloat` branch;
  // the bigint avoids f64 round-trip loss above 2^53.
  if (value.kind === 'int' && bound.exactInt && bound.integerBits !== undefined) {
    if (value.bits < bound.integerBits) return -1;
    if (value.bits > bound.integerBits) return 1;
    return 0;
  }
  if (value.f < bound.value) return -1;
  if (value.f > bound.value) return 1;
  return 0;
}

function boundUnitMismatch(bound: NumericBound, valueUnit: string | undefined): boolean {
  if (bound.unit === undefined) return false;
  if (valueUnit === undefined) return true;
  return bound.unit !== valueUnit;
}

function checkNumericBounds(node: NumberNode, nb: NumericBounds): MatchFail | null {
  const value = readNumericValue(node);
  if (nb.integer && !valueIsInteger(value)) {
    return numberNotInteger(value.f);
  }
  if (nb.min) {
    if (boundUnitMismatch(nb.min, node.unit)) {
      return numericBoundUnitMismatch(node.unit, nb.min.unit);
    }
    const ord = compareToBound(value, nb.min);
    if (nb.exclusiveMin) {
      if (ord !== 1) return numberAtOrBelowExclusiveMin(value.f, nb.min.value, nb.min.unit);
    } else if (ord === -1) {
      return numberBelowMin(value.f, nb.min.value, nb.min.unit);
    }
  }
  if (nb.max) {
    if (boundUnitMismatch(nb.max, node.unit)) {
      return numericBoundUnitMismatch(node.unit, nb.max.unit);
    }
    const ord = compareToBound(value, nb.max);
    if (nb.exclusiveMax) {
      if (ord !== -1) return numberAtOrAboveExclusiveMax(value.f, nb.max.value, nb.max.unit);
    } else if (ord === 1) {
      return numberAboveMax(value.f, nb.max.value, nb.max.unit);
    }
  }
  // Divisibility last: a value that is fractional, or outside the range,
  // has a more basic problem than "not a multiple", and this checker
  // reports the first failure it finds. Parity with Zig's ordering.
  if (nb.multipleOf) {
    if (boundUnitMismatch(nb.multipleOf, node.unit)) {
      return numericBoundUnitMismatch(node.unit, nb.multipleOf.unit);
    }
    if (!isMultipleOf(value, nb.multipleOf)) {
      return numberNotMultiple(value.f, nb.multipleOf.value, nb.multipleOf.unit);
    }
  }
  return null;
}

// True when `value` is an exact multiple of `bound`. Mirrors Zig's
// `isMultipleOf`, and the bigint path is the whole reason this is not a
// one-line `%`: an f64 remainder rounds 2^53 + 1 to an even number and
// reports it as a multiple of 2. Three cases, matching the reference:
//
//   1. both integral   → bigint remainder, exact at any magnitude;
//   2. fractional value, integral divisor → never a multiple;
//   3. fractional divisor → f64 remainder against a relative epsilon,
//      because binary floating point has no exact answer there. The
//      loader warns at the declaration.
//
// Sign is irrelevant on both sides. Zero / non-finite divisors are
// rejected at load, so this never divides by zero.
function isMultipleOf(value: NumericValue, bound: NumericBound): boolean {
  const d = bound.value;
  const divisorIntegral = Number.isFinite(d) && Math.floor(d) === d;
  if (divisorIntegral) {
    const db = bound.integerBits ?? BigInt(d);
    if (db === 0n) return true; // unreachable: rejected at load.
    let nb: bigint;
    if (value.kind === 'int') {
      nb = value.bits;
    } else if (Number.isFinite(value.f) && Math.floor(value.f) === value.f) {
      nb = BigInt(value.f);
    } else {
      // Case 2: a fractional (or non-finite) value under a whole divisor.
      return false;
    }
    return nb % db === 0n;
  }

  // Case 3.
  if (!Number.isFinite(value.f)) return false;
  const rem = Math.abs(value.f % d);
  const eps = Math.abs(d) * 1e-9;
  return rem <= eps || Math.abs(d) - rem <= eps;
}

type ReprSpec = { readonly min: number; readonly max: number; readonly integer: boolean };

// Closed (min, max, integer) triple per GPU type. Range-only — precision
// narrowing is the emitter's accepted lossy step. Mirrors
// `Plugin.ValueKind.Repr.spec` in src/Plugin.zig; the f32/f16 maxima are
// the f64-widened `floatMax` magnitudes. Exhaustive switch (no default):
// adding a `Repr` variant without a case is a `noImplicitReturns` error.
function reprSpec(repr: Repr): ReprSpec {
  switch (repr) {
    case 'f32':
      return { min: -3.4028234663852886e38, max: 3.4028234663852886e38, integer: false };
    case 'f16':
      return { min: -65504, max: 65504, integer: false };
    case 'u16':
      return { min: 0, max: 65535, integer: true };
    case 'u32':
      return { min: 0, max: 4294967295, integer: true };
    case 'i32':
      return { min: -2147483648, max: 2147483647, integer: true };
  }
}

// Repr range / integrality check. Integrality first, so `70000.5` under
// `:repr u16` reads as "not an integer" rather than "out of range".
// Range-only. Parity with Zig's `checkReprValue`.
function checkReprValue(node: NumberNode, repr: Repr): MatchFail | null {
  const value = readNumericValue(node);
  const spec = reprSpec(repr);
  if (spec.integer && !valueIsInteger(value)) {
    return reprOutOfRange(value.f, repr, 'not_integer');
  }
  if (value.f < spec.min || value.f > spec.max) {
    return reprOutOfRange(value.f, repr, 'out_of_range');
  }
  return null;
}

function reprOutOfRange(v: number, repr: Repr, reason: 'out_of_range' | 'not_integer'): MatchFail {
  return {
    code: 'repr_out_of_range',
    message: () =>
      reason === 'not_integer'
        ? `value ${v} is not an integer — :repr \`${repr}\` requires a whole number`
        : `value ${v} is out of range for :repr \`${repr}\``,
  };
}

function formatBound(v: number, unit: string | undefined): string {
  return unit !== undefined ? `${v}${unit}` : `${v}`;
}

function numberBelowMin(v: number, b: number, unit: string | undefined): MatchFail {
  return {
    code: 'number_below_min',
    message: () => `value ${v} below minimum ${formatBound(b, unit)}`,
  };
}

function numberAboveMax(v: number, b: number, unit: string | undefined): MatchFail {
  return {
    code: 'number_above_max',
    message: () => `value ${v} above maximum ${formatBound(b, unit)}`,
  };
}

function numberAtOrBelowExclusiveMin(v: number, b: number, unit: string | undefined): MatchFail {
  return {
    code: 'number_at_or_below_exclusive_min',
    message: () => `value ${v} must be strictly greater than ${formatBound(b, unit)}`,
  };
}

function numberAtOrAboveExclusiveMax(v: number, b: number, unit: string | undefined): MatchFail {
  return {
    code: 'number_at_or_above_exclusive_max',
    message: () => `value ${v} must be strictly less than ${formatBound(b, unit)}`,
  };
}

function numberNotInteger(v: number): MatchFail {
  return {
    code: 'number_not_integer',
    message: () => `value ${v} is not an integer`,
  };
}

function numberNotMultiple(v: number, b: number, unit: string | undefined): MatchFail {
  return {
    code: 'number_not_multiple',
    message: () => `value ${v} is not a multiple of ${formatBound(b, unit)}`,
  };
}

function numericBoundUnitMismatch(
  valueUnit: string | undefined,
  boundUnit: string | undefined,
): MatchFail {
  const vu = valueUnit !== undefined ? `\`${valueUnit}\`` : '(none)';
  const bu = boundUnit !== undefined ? `\`${boundUnit}\`` : '(none)';
  return {
    code: 'numeric_bound_unit_mismatch',
    message: () => `value unit ${vu} does not match bound unit ${bu}`,
  };
}

function checkStringBoundsValue(text: string, sb: StringBounds): MatchFail | null {
  if (sb.minLen !== undefined || sb.maxLen !== undefined) {
    const cp = StringFormats.codepointLength(text);
    if (sb.minLen !== undefined && cp < sb.minLen) {
      return {
        code: 'string_too_short',
        message: () => `string length ${cp} is below :min-len ${sb.minLen}`,
      };
    }
    if (sb.maxLen !== undefined && cp > sb.maxLen) {
      return {
        code: 'string_too_long',
        message: () => `string length ${cp} is above :max-len ${sb.maxLen}`,
      };
    }
  }
  if (sb.format && !StringFormats.check(sb.format, text)) {
    return {
      code: 'string_format_mismatch',
      message: () => `string "${text}" does not satisfy :format \`${sb.format}\``,
    };
  }
  return null;
}

function emit(
  diags: Diagnostic[],
  span: { start: number; end: number },
  path: readonly string[],
  code: DiagnosticCode,
  message: string,
): void {
  diags.push({
    code,
    message,
    path: [...path],
    span,
    severity: 'err',
  });
}
