// Projections that put the reader and the engine into the same shape.
//
// Two independent legs share these helpers:
//
//   * `readerRows` mirrors `Edit.nodeTable`'s pre-order walk. A kvpair
//     contributes no row; its value carries the pair's key as `seg` and the
//     key's span as `key_span`. Positional steps count with kvpairs skipped,
//     exactly as `pushChildren` counts them.
//   * `projectValue` mirrors `Json.toJson`'s canonical encoding: tagged
//     `$kw` / `$sym` / `$num` / `$date` / `$time` atoms, `$form` + `$ns` +
//     `$children` containers, and sigil-escaped `$`-prefixed keys.
//
// `projectValue` is deliberately a *lossy* projection for duplicate keys:
// assigning a repeated key keeps the last value, which is the only thing a
// JSON object can carry. The oracle treats a root with duplicates as a named
// exclusion and uses this projection only to prove that the lost keys are the
// only difference.
//
// Numbers are projected with the same rule the engine applies: exact integers
// stay exact (as `bigint` outside the JS safe range), unit-bearing and
// float-shaped literals project their f64 view. This module never converts an
// exact integer through `Number` before deciding it is outside the safe range.

import type { ReadDiagnostic } from '../../src/diagnostics.ts';
import type { Node, NumberNode, Span } from '../../src/nodes.ts';
import type { EngineDiagnostic, EngineNodeTable, JsonValue } from './oracle.ts';

/** One comparable node-table row: engine fields or reader fields. */
export interface NodeRow {
  readonly parent: number;
  readonly root: number;
  readonly seg: string | number | null;
  readonly kind: string;
  readonly span: readonly [number, number];
  readonly head_span?: readonly [number, number];
  readonly key_span?: readonly [number, number];
}

/** One comparable parse diagnostic. Paths and prose are not engine channels. */
export interface ComparableDiagnostic {
  readonly code: string;
  readonly severity: 'err' | 'warning';
  readonly span: readonly [number, number];
}

const I64_MAX = 9223372036854775807n;
const MAX_SAFE_BIGINT = BigInt(Number.MAX_SAFE_INTEGER);
const MIN_SAFE_BIGINT = BigInt(Number.MIN_SAFE_INTEGER);

/** The `sjon_node_table` rows in the shape the reader projection produces. */
export function engineRows(table: EngineNodeTable): NodeRow[] {
  return table.nodes.map((row) => {
    const base: NodeRow = {
      parent: row.parent,
      root: row.root,
      seg: row.seg,
      kind: row.kind,
      span: row.span,
    };
    const withHead = row.head_span === undefined ? base : { ...base, head_span: row.head_span };
    return row.key_span === undefined ? withHead : { ...withHead, key_span: row.key_span };
  });
}

/** The engine's `(code, severity, span)` diagnostic sequence. */
export function engineDiagnostics(table: EngineNodeTable): ComparableDiagnostic[] {
  return table.diagnostics.map((diagnostic: EngineDiagnostic) => ({
    code: diagnostic.code,
    severity: diagnostic.severity,
    span: [diagnostic.span.start, diagnostic.span.end] as const,
  }));
}

/** The reader's `(code, severity, span)` diagnostic sequence. */
export function readerDiagnostics(diagnostics: readonly ReadDiagnostic[]): ComparableDiagnostic[] {
  return diagnostics.map((diagnostic) => ({
    code: diagnostic.code,
    severity: diagnostic.severity,
    span: [diagnostic.span.start, diagnostic.span.end] as const,
  }));
}

/**
 * Project a reader forest into `sjon_node_table` rows.
 *
 * Complexity O(n). The walk is explicit and pre-order; a parent always
 * precedes its children, and siblings stay in source order.
 */
export function readerRows(roots: readonly Node[]): NodeRow[] {
  const rows: NodeRow[] = [];

  const visit = (
    node: Node,
    parent: number,
    root: number,
    seg: string | number | null,
    pairKeySpan: Span | null,
  ): void => {
    rows.push(rowFor(node, parent, root, seg, pairKeySpan));
    const rowIndex = rows.length - 1;
    switch (node.tag) {
      case 'form': {
        let positional = 0;
        for (const child of node.children) {
          if (child.tag === 'kvpair') {
            visit(child.value, rowIndex, root, child.key, child.keySpan);
          } else {
            visit(child, rowIndex, root, positional, null);
            positional += 1;
          }
        }
        break;
      }
      case 'vector':
        node.elements.forEach((element, elementIndex) => {
          visit(element, rowIndex, root, elementIndex, null);
        });
        break;
      default:
        break;
    }
  };

  roots.forEach((root, rootIndex) => {
    visit(root, -1, rootIndex, null, null);
  });
  return rows;
}

function rowFor(
  node: Node,
  parent: number,
  root: number,
  seg: string | number | null,
  pairKeySpan: Span | null,
): NodeRow {
  const base: NodeRow = {
    parent,
    root,
    seg,
    kind: nodeKind(node),
    span: [node.span.start, node.span.end] as const,
  };
  const withHead =
    node.tag === 'form'
      ? { ...base, head_span: [node.headSpan.start, node.headSpan.end] as const }
      : base;
  return pairKeySpan === null
    ? withHead
    : { ...withHead, key_span: [pairKeySpan.start, pairKeySpan.end] as const };
}

/**
 * Map one public number node back to the engine's four numeric tags.
 *
 * The reader has a single `NumberNode`; the engine distinguishes by origin:
 * a unit means `number_with_unit`, an exact `integer` above `i64.max` means
 * `number_u64`, any other exact integer means `number_i64`, and everything
 * else is the f64-backed `number`.
 */
function numberKind(node: NumberNode): string {
  if (node.unit !== null) return 'number_with_unit';
  if (node.integer !== null) return node.integer > I64_MAX ? 'number_u64' : 'number_i64';
  return 'number';
}

function nodeKind(node: Node): string {
  switch (node.tag) {
    case 'form':
      return 'form';
    case 'vector':
      return 'vector';
    case 'number':
      return numberKind(node);
    case 'date':
      return 'date';
    case 'time':
      return 'time';
    case 'string':
      return 'string';
    case 'symbol':
      return 'symbol';
    case 'keyword':
      return 'keyword';
    case 'boolean':
      return node.value ? 'boolean_true' : 'boolean_false';
    case 'nil':
      return 'nil';
    case 'kvpair':
      throw new Error('kvpair reached the row projection; it should fold into its value');
    default:
      return assertNever(node);
  }
}

/**
 * Canonical JSON projection of one reader root, matching `Json.toJson`.
 *
 * A repeated key assigns twice, so the object retains the last value: a
 * duplicate-key root is excluded from strict value comparison, and this
 * projection is what proves the engine lost only those keys.
 */
export function projectValue(node: Node): JsonValue {
  switch (node.tag) {
    case 'nil':
      return null;
    case 'boolean':
      return node.value;
    case 'number':
      return projectNumber(node);
    case 'date':
      return { $date: `${pad(node.year, 4)}-${pad(node.month, 2)}-${pad(node.day, 2)}` };
    case 'time': {
      const fraction = node.millisecond === 0 ? '' : `.${pad(node.millisecond, 3)}`;
      return {
        $time: `${pad(node.hour, 2)}:${pad(node.minute, 2)}:${pad(node.second, 2)}${fraction}`,
      };
    }
    case 'string':
      return node.value;
    case 'symbol':
      return { $sym: node.value };
    case 'keyword':
      return { $kw: node.value };
    case 'vector':
      return node.elements.map((element) => projectValue(element));
    case 'form': {
      const object: Record<string, JsonValue> = { $form: escapeKey(node.head) };
      if (node.namespace !== null) object['$ns'] = node.namespace;
      const children: JsonValue[] = [];
      for (const child of node.children) {
        if (child.tag === 'kvpair') {
          object[escapeKey(child.key)] = projectValue(child.value);
        } else {
          children.push(projectValue(child));
        }
      }
      if (children.length > 0) object['$children'] = children;
      return object;
    }
    case 'kvpair':
      throw new Error('kvpair reached the value projection; it should fold into its value');
    default:
      return assertNever(node);
  }
}

function projectNumber(node: NumberNode): JsonValue {
  if (node.unit !== null) return { $num: [normalizeF64(node.value), node.unit] };
  if (node.integer !== null) {
    if (node.integer > MAX_SAFE_BIGINT || node.integer < MIN_SAFE_BIGINT) return node.integer;
    return Number(node.integer);
  }
  return normalizeF64(node.value);
}

/** JSON has one zero; a parsed `-0` literal is the same number as `0`. */
function normalizeF64(value: number): number {
  return Object.is(value, -0) ? 0 : value;
}

/** `Json.escapeKey`: one extra `$` for a key that already starts with one. */
function escapeKey(key: string): string {
  return key.startsWith('$') ? `$${key}` : key;
}

function pad(value: number, width: number): string {
  return String(value).padStart(width, '0');
}

/**
 * Count repeated kvpair keys anywhere in a reader root.
 *
 * One collision means the root's JSON object cannot carry every pair, which
 * is the `duplicate-key` exclusion's reason.
 */
export function countDuplicateKeyCollisions(root: Node): number {
  let collisions = 0;
  const walk = (node: Node): void => {
    switch (node.tag) {
      case 'form': {
        const seen = new Set<string>();
        for (const child of node.children) {
          if (child.tag === 'kvpair') {
            if (seen.has(child.key)) collisions += 1;
            seen.add(child.key);
            walk(child.value);
          } else {
            walk(child);
          }
        }
        break;
      }
      case 'vector':
        for (const element of node.elements) walk(element);
        break;
      case 'kvpair':
        walk(node.value);
        break;
      default:
        break;
    }
  };
  walk(root);
  return collisions;
}

/** True when an engine value contains a `$expr` collapse anywhere. */
export function containsExpressionCollapse(value: JsonValue): boolean {
  if (Array.isArray(value)) return value.some((element) => containsExpressionCollapse(element));
  if (isJsonObject(value)) {
    if (Object.hasOwn(value, '$expr')) return true;
    return Object.values(value).some((element) => containsExpressionCollapse(element));
  }
  return false;
}

/** Every `$expr` head in an engine value, in walk order. */
export function collectExpressionHeads(value: JsonValue): string[] {
  const heads: string[] = [];
  const walk = (current: JsonValue): void => {
    if (Array.isArray(current)) {
      for (const element of current) walk(element);
      return;
    }
    if (isJsonObject(current)) {
      const expression = current['$expr'];
      if (Array.isArray(expression)) {
        const head = expression[0];
        if (typeof head === 'string') heads.push(head);
      }
      for (const element of Object.values(current)) walk(element);
    }
  };
  walk(value);
  return heads;
}

/** Every form head in a reader root, in pre-order. */
export function collectFormHeads(root: Node): string[] {
  const heads: string[] = [];
  const walk = (node: Node): void => {
    switch (node.tag) {
      case 'form':
        heads.push(node.head);
        for (const child of node.children) walk(child);
        break;
      case 'vector':
        for (const element of node.elements) walk(element);
        break;
      case 'kvpair':
        walk(node.value);
        break;
      default:
        break;
    }
  };
  walk(root);
  return heads;
}

export interface FormHead {
  readonly head: string;
  readonly namespace: string | null;
}

/**
 * Every form in a reader root that carries at least one kvpair.
 *
 * An expression form with pairs cannot become `$expr` and makes
 * `sjon_to_json` fail with `InvalidExprForm`; this list is how the oracle
 * proves that failure is still the expression exclusion's reason.
 */
export function formsWithKvpairs(root: Node): FormHead[] {
  const forms: FormHead[] = [];
  const walk = (node: Node): void => {
    switch (node.tag) {
      case 'form': {
        if (node.children.some((child) => child.tag === 'kvpair')) {
          forms.push({ head: node.head, namespace: node.namespace });
        }
        for (const child of node.children) walk(child);
        break;
      }
      case 'vector':
        for (const element of node.elements) walk(element);
        break;
      case 'kvpair':
        walk(node.value);
        break;
      default:
        break;
    }
  };
  walk(root);
  return forms;
}

/**
 * Structural equality for projected JSON.
 *
 * A `bigint`/`number` pair is compared through `Number(bigint)`: the engine
 * prints an f64 `.number` that is integer-shaped above 2^53 as decimal digits,
 * which the bigint-aware parse reads as an exact integer. The number's
 * *classification* is pinned independently by the structural leg, so this
 * cross-type rule cannot hide a `number_i64`/`number` mix-up; it only lets the
 * f64 value compare as the f64 it is in the source. Two bigints compare
 * exactly, which is where the i64/u64 boundary check lives.
 */
export function jsonEqual(left: JsonValue, right: JsonValue): boolean {
  if (typeof left === 'bigint' || typeof right === 'bigint') {
    if (typeof left === 'bigint' && typeof right === 'bigint') return left === right;
    if (typeof left === 'bigint') return typeof right === 'number' && Number(left) === right;
    return typeof left === 'number' && left === Number(right);
  }
  if (Array.isArray(left) || Array.isArray(right)) {
    if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) return false;
    return left.every((element, index) => {
      const other = right[index];
      return other !== undefined && jsonEqual(element, other);
    });
  }
  if (isJsonObject(left) || isJsonObject(right)) {
    if (!isJsonObject(left) || !isJsonObject(right)) return false;
    const leftKeys = Object.keys(left);
    if (leftKeys.length !== Object.keys(right).length) return false;
    for (const key of leftKeys) {
      if (!Object.hasOwn(right, key)) return false;
      const leftValue = left[key];
      const rightValue = right[key];
      if (leftValue === undefined || rightValue === undefined) return false;
      if (!jsonEqual(leftValue, rightValue)) return false;
    }
    return true;
  }
  return left === right;
}

/** Render a projected value for a failure message; bigints stay readable. */
export function renderJson(value: JsonValue): string {
  return (
    JSON.stringify(value, (_key: string, current: unknown) =>
      typeof current === 'bigint' ? `${current}n` : current,
    ) ?? 'undefined'
  );
}

/** True when every `required` value is present in `available` by multiplicity. */
export function multisetContains(
  available: readonly string[],
  required: readonly string[],
): boolean {
  const counts = new Map<string, number>();
  for (const value of available) counts.set(value, (counts.get(value) ?? 0) + 1);
  for (const value of required) {
    const remaining = counts.get(value) ?? 0;
    if (remaining === 0) return false;
    counts.set(value, remaining - 1);
  }
  return true;
}

function isJsonObject(value: JsonValue): value is { readonly [key: string]: JsonValue } {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function assertNever(value: never): never {
  throw new Error(`unhandled node tag: ${JSON.stringify(value)}`);
}
