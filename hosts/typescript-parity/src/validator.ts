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

import type { Node, FormNode, KvPairNode, NumberNode, VectorNode, Span } from './ast.ts';
import type { Diagnostic, DiagnosticCode } from './diagnostics.ts';
import type {
  Schema,
  FormSpec,
  ExprFunc,
  Member,
  ValueType,
  ValueKind,
  NumericBound,
  NumericBounds,
  QualifiedRef,
  Repr,
  StringBounds,
} from './plugin.ts';
import {
  MAX_KIND_DEPTH,
  checkArity,
  effectiveOptional,
  lookupExprFunc,
  lookupForm,
  lookupValueKind,
  paramTypeAt,
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
  const fn = node as FormNode;
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
  readonly targetsByHead: ReadonlyMap<string, CrossRefTargetSpec>;
  // Cross-ref kind name → its target spec, for the validator's resolve
  // path which knows the kind, not the head.
  readonly targetsByKind: ReadonlyMap<string, CrossRefTargetSpec>;
  readonly scopeOpeners: ReadonlySet<string>; // canonical scope-opener forms
  readonly cycleDiags: readonly Diagnostic[];
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
      const canonicalTarget = canonicalize(schema, cr.target);
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

export function validate(schema: Schema, roots: readonly Node[]): readonly Diagnostic[] {
  const diags: Diagnostic[] = [];

  // Pre-pass: build cross-ref registry over the forest, capturing
  // duplicate-name diagnostics, lexical scope frames, and per-scope
  // edge graphs for cycle detection.
  const registry = buildCrossRefIndex(schema, roots, diags);

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
): CrossRefRegistry {
  // 1. Cross-ref kinds → canonical target specs.
  const targetsByHead = new Map<string, CrossRefTargetSpec>();
  const targetsByKind = new Map<string, CrossRefTargetSpec>();
  for (const p of schema.plugins) {
    for (const k of p.valueKinds) {
      const cr = k.crossRef;
      if (!cr) continue;
      const canonicalTarget = canonicalize(schema, cr.target);
      if (!canonicalTarget) continue;
      const scopeForm = cr.scopeForm ? canonicalize(schema, cr.scopeForm) : null;
      const spec: CrossRefTargetSpec = {
        canonicalTarget,
        nameKey: cr.nameKey ?? 'name',
        scopeForm,
        acyclic: cr.acyclic ?? false,
      };
      // First-wins: if two kinds target the same form, the first one
      // sets the head's resolution policy.
      const bareHead = bareFromCanonical(canonicalTarget);
      if (!targetsByHead.has(bareHead)) targetsByHead.set(bareHead, spec);
      targetsByKind.set(k.name, spec);
    }
  }

  // 2. Acyclic specs (subset with `:acyclic true` and self-edges).
  const acyclicSpecs = collectAcyclicSpecs(schema);

  // 3. Scope-opener canonicals: union of every cross-ref's scope_form.
  const scopeOpeners = new Set<string>();
  for (const t of targetsByHead.values()) {
    if (t.scopeForm) scopeOpeners.add(t.scopeForm);
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
  };
}

function walkIndex(
  schema: Schema,
  node: Node,
  treeIdx: number,
  treeScope: ScopeId,
  scopeStack: ScopeFrame[],
  targetsByHead: ReadonlyMap<string, CrossRefTargetSpec>,
  acyclicSpecs: readonly AcyclicSpec[],
  scopeOpeners: ReadonlySet<string>,
  byScope: Map<ScopeId, Map<string, Set<string>>>,
  cycleNodesBySpec: Map<ScopeId, CycleNode[]>[],
  diags: Diagnostic[],
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

    const targetSpec = targetsByHead.get(node.head);
    if (targetSpec) {
      registerInstance(node, targetSpec, treeScope, scopeStack, byScope, diags);
    }

    for (let i = 0; i < acyclicSpecs.length; i++) {
      const spec = acyclicSpecs[i]!;
      if (canonical !== spec.canonicalTarget) continue;
      captureCycleNode(node, treeIdx, spec, treeScope, scopeStack, cycleNodesBySpec[i]!);
    }

    for (const ch of node.children) {
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
      );
    }

    if (pushed) scopeStack.pop();
  } else if (node.tag === 'vector') {
    for (const e of (node as VectorNode).elements) {
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
      );
    }
  } else if (node.tag === 'kvpair') {
    walkIndex(
      schema,
      (node as KvPairNode).value,
      treeIdx,
      treeScope,
      scopeStack,
      targetsByHead,
      acyclicSpecs,
      scopeOpeners,
      byScope,
      cycleNodesBySpec,
      diags,
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
): void {
  // Lexical tolerance: silently skip when the kvpair is missing or
  // its value isn't a symbol — those errors surface elsewhere
  // (missing-required-key / wrong_underlying).
  for (const ch of form.children) {
    if (ch.tag !== 'kvpair') continue;
    if (ch.key !== spec.nameKey) continue;
    if (ch.value.tag !== 'symbol') return;
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
      diags.push({
        code: 'duplicate_cross_ref_target',
        message: `duplicate cross-ref name \`${text}\` on form \`${form.head}\``,
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
      for (const elem of (ch.value as VectorNode).elements) {
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
/// form value frame when the enclosing slot's `KeySpec.localForms` is
/// non-empty: the value's head then resolves local-first against `registry`,
/// and a terminal miss reports `unknown_local_form` at `slotPath` (the
/// enclosing kvpair, e.g. `[canvas shape]`). Mirrors the Zig tree path's
/// `Frame.local_form_registry` / `local_form_slot_path` seam.
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
      const formNode = node as FormNode;
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
      for (const child of formNode.children) {
        if (child.tag === 'kvpair') {
          const kvPath = [...path, child.key];
          const value = child.value;
          let valuePath = kvPath;
          let childScope: LocalFormScope | null = null;
          if (value.tag === 'form') {
            if (value.head.length > 0) valuePath = [...kvPath, value.head];
            // Attach the slot's local registry when the matching KeySpec
            // carries local forms (slot path = the kvpair's own path).
            if (ownSpec) {
              for (const k of ownSpec.keys) {
                if (k.name !== child.key) continue;
                if (k.localForms && k.localForms.length > 0) {
                  childScope = { registry: k.localForms, slotPath: kvPath };
                }
                break;
              }
            }
          }
          visit(schema, registry, value, valuePath, chain, treeScope, treeIdx, diags, childScope);
        } else {
          let step: string;
          if (child.tag === 'form' && child.head.length > 0) {
            step = child.head;
          } else {
            step = String(positionalCount);
          }
          visit(schema, registry, child, [...path, step], chain, treeScope, treeIdx, diags, null);
          positionalCount++;
        }
      }
      break;
    }
    case 'vector': {
      let i = 0;
      for (const elem of (node as VectorNode).elements) {
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
      visit(
        schema,
        registry,
        (node as KvPairNode).value,
        path,
        scopeChain,
        treeScope,
        treeIdx,
        diags,
        null,
      );
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
  // Positional ordinal (mirrors Zig's `positional_n`) and the per-form
  // set of already-seen flag names (mirrors Zig's `seen_flags`).
  let posIndex = 0;
  const seenFlags = new Set<string>();
  for (const child of node.children) {
    if (child.tag === 'kvpair') {
      const matchIdx = spec.keys.findIndex((k) => k.name === child.key);
      if (matchIdx >= 0) {
        seenIdx.add(matchIdx);
        const k = spec.keys[matchIdx]!;
        const fail = matchType(
          schema,
          registry,
          child.value,
          k.valueType,
          scopeChain,
          treeScope,
          0,
        );
        if (fail) {
          emit(
            diags,
            child.value.span,
            [...path, child.key],
            fail.code,
            fail.message(spec.name, child.key),
          );
        } else {
          emitDeprecatedMember(diags, schema, k.valueType, child.value, [...path, child.key]);
          emitStringPatternUnsupported(diags, schema, k.valueType, child.value, [
            ...path,
            child.key,
          ]);
        }
      } else if (!spec.open) {
        emit(
          diags,
          child.keySpan,
          [...path, child.key],
          'unknown_key',
          `unknown keyword \`:${child.key}\` in form \`${spec.name}\``,
        );
      }
    } else {
      // Form children step by head; others by positional index. Mirrors
      // Zig's `positionalStep` so paths line up across hosts.
      const step = child.tag === 'form' && child.head.length > 0 ? child.head : String(posIndex);
      switch (spec.positional.kind) {
        case 'none':
          if (!spec.open) {
            emit(
              diags,
              child.span,
              [...path, step],
              'positional_not_allowed',
              `form \`${spec.name}\` does not accept positional children`,
            );
          }
          break;
        case 'any':
          break;
        case 'kind': {
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
              child.span,
              [...path, step],
              fail.code,
              fail.message(spec.name, '<positional>'),
            );
          } else {
            emitStringPatternUnsupported(
              diags,
              schema,
              { kind: 'named', name: spec.positional.name, namespace: spec.positional.namespace },
              child,
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

  if (!spec.open) {
    for (let ki = 0; ki < spec.keys.length; ki++) {
      const k = spec.keys[ki]!;
      // A defaulted key is effectively optional — the default fills the slot,
      // so its absence is not `missing_required_key` (mirrors the Zig
      // validator's `effectiveOptional` gate in both tree + binary paths).
      if (effectiveOptional(k)) continue;
      if (seenIdx.has(ki)) continue;
      emit(
        diags,
        node.headSpan,
        path,
        'missing_required_key',
        `form \`${spec.name}\` is missing required keyword \`:${k.name}\``,
      );
    }
  }
}

interface MatchFail {
  readonly code: DiagnosticCode;
  message(formName: string, slot: string): string;
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
  // check to the `.form` underlying branch below; otherwise dispatch
  // through the form-expression resolver so refined-named primitives
  // (vec3-like kinds) reject coarse expression results consistently.
  if (node.tag === 'form' && kind.underlying !== 'form') {
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
        const fail = checkNumericBounds(node as NumberNode, kind.numeric);
        if (fail) return fail;
      }
      // Repr narrowing is orthogonal to :numeric — both may be set and
      // each is checked independently (parity with the Zig .number arm).
      if (kind.repr) {
        const fail = checkReprValue(node as NumberNode, kind.repr);
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
      if (node.tag !== 'symbol') return wrongUnderlying('symbol');
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
          return notCrossRef(node.text, bareFromCanonical(targetSpec.canonicalTarget));
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
        const elements = (node as VectorNode).elements;
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
            if (fail) return wrapElementFail(i, fail);
          }
        }
      }
      return null;
    case 'form':
      if (node.tag !== 'form') return wrongUnderlying('form');
      if (kind.heads && !kind.heads.includes(node.head)) {
        return notHeadMember(node.head, kind.heads);
      }
      return null;
    case 'union_of': {
      const us = kind.unionOf;
      if (!us) return null;
      // First-match dispatch: the first alternative that accepts wins.
      // When none does, the value is rejected (parity with the Zig
      // validator's union arm — the previous stub accepted everything,
      // which was dead code until `scalar-or-ref` made unions loadable).
      for (const alt of us.alternatives) {
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
      }
      return unionNoBranchMatched(node, us.alternatives);
    }
  }
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
  const text = value.tag === 'symbol' ? value.text : value.tag === 'string' ? value.value : null;
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

function notHeadMember(got: string, allowed: readonly string[]): MatchFail {
  return {
    code: 'not_head_member',
    message: () => `head \`${got}\` is not in [${allowed.join(', ')}]`,
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

function wrapElementFail(idx: number, inner: MatchFail): MatchFail {
  return {
    code: inner.code,
    message: (formName, slot) => `element ${idx}: ${inner.message(formName, slot)}`,
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
  return null;
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
